--- Turbo.lua IO Stream module.
-- High-level wrappers for asynchronous socket communication.
-- All API's are callback based and depend on the __Turbo IOLoop module__.
--
-- Implementations available:
--
-- * IOStream, non-blocking sockets.
-- * SSLIOStream, non-blocking SSL sockets using OpenSSL.
--
-- Copyright 2011, 2012, 2013 John Abrahamsen
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


local log =         require "turbo.log"
local ioloop =      require "turbo.ioloop"
local deque =       require "turbo.structs.deque"
local buffer =      require "turbo.structs.buffer"
local socket =      require "turbo.socket_ffi"
local sockutils =   require "turbo.sockutil"
local util =        require "turbo.util"
-- __Global value__ _G.TURBO_SSL allows the user to enable the SSL module.
local crypto =      _G.TURBO_SSL and require "turbo.crypto"
local bit =         require "bit"
local ffi =         require "ffi"
require "turbo.cdef"
require "turbo.3rdparty.middleclass"
local SOL_SOCKET =  socket.SOL_SOCKET
local SO_RESUSEADDR =   socket.SO_REUSEADDR
local O_NONBLOCK =  socket.O_NONBLOCK
local F_SETFL =     socket.F_SETFL
local F_GETFL =     socket.F_GETFL
local SOCK_STREAM = socket.SOCK_STREAM
local INADDRY_ANY = socket.INADDR_ANY
local AF_INET =     socket.AF_INET
local AF_INET6 =    socket.AF_INET6
local AF_UNSPEC =   socket.AF_UNSPEC
local EWOULDBLOCK = socket.EWOULDBLOCK
local EINPROGRESS = socket.EINPROGRESS
local ECONNRESET = socket.ECONNRESET
local EPIPE =       socket.EPIPE
local EAGAIN =      socket.EAGAIN
local libtffi_loaded, libtffi = pcall(ffi.load, "tffi_wrap")
if not libtffi_loaded then
    libtffi_loaded, libtffi = 
        pcall(ffi.load, "/usr/local/lib/libtffi_wrap.so")
    if not libtffi_loaded then 
        error("Could not load libtffi_wrap.so. \
            Please run makefile and ensure that installation is done correct.")
    end
end

local bitor, bitand, min, max =  bit.bor, bit.band, math.min, math.max

-- __Global value__ _G.TURBO_SOCKET_BUFFER_SZ allows the user to set 
-- his own socket buffer size to be used by the module. Defaults to 4096 bytes.
_G.TURBO_SOCKET_BUFFER_SZ = _G.TURBO_SOCKET_BUFFER_SZ or 4096
local buf = ffi.new("char[?]", _G.TURBO_SOCKET_BUFFER_SZ)

local iostream = {} -- iostream namespace

--- The IOStream class is implemented through the use of the IOLoop class, 
-- and are utilized e.g in the RequestHandler class and its subclasses. 
-- They provide a non-blocking interface and support callbacks for most of 
-- its operations. For read operations the class supports methods suchs as 
-- read until delimiter, read n bytes and read until close. The class has 
-- its own write buffer and there is no need to buffer data at any other level. 
-- The default maximum write buffer is defined to 100 MB. This can be 
-- defined on class initialization.
iostream.IOStream = class('IOStream')

--- Create a new IOStream instance.
-- @param fd (Number) File descriptor, either open or closed. If closed then, 
-- the IOStream:connect() method can be used to connect.
-- @param io_loop (IOLoop object) IOLoop class instance to use for event 
-- processing. If none is set then the global instance is used, see the 
-- ioloop.instance() function.
-- @param max_buffer_size (Number) The maximum number of bytes that can be 
-- held in internal buffer before flushing must occur. 
-- If none is set, 104857600 are used as default.
function iostream.IOStream:initialize(fd, io_loop, max_buffer_size)
    self.socket = assert(fd, "argument #1, fd, is not a number.")
    self.io_loop = io_loop or ioloop.instance()
    self.max_buffer_size = max_buffer_size or 104857600
    self._read_buffer = buffer(1024)
    self._read_buffer_size = 0
    self._read_buffer_offset = 0
    self._read_scan_offset = 0
    self._write_buffer = buffer(1024)
    self._write_buffer_size = 0
    self._write_buffer_offset = 0
    self._pending_callbacks = 0
    self._read_until_close = false
    self._connecting = false
    local rc, msg = socket.set_nonblock_flag(self.socket)
    if (rc == -1) then
        error("[iostream.lua] " .. msg)
    end
end

--- Connect to a address without blocking.
-- @param address (String)  The host to connect to. Either hostname or IP.
-- @param port (Number)  The port to connect to. E.g 80.
-- @param family (Number)  Socket family. Optional. Pass nil to guess.
-- @param callback (Function)  Optional callback for "on successfull connect".
-- @param errhandler (Function) Optional callback for "on error".
-- @param arg Optional argument for callback.
-- @return (Number) -1 and error string on fail, 0 on success.
function iostream.IOStream:connect(address, port, family, 
    callback, errhandler, arg)
    assert(type(address) == "string", "argument #1, address, is not a string.")
    assert(type(port) == "number", "argument #2, ports, is not a number.")
    assert((not family or type(family) == "number"), 
        "argument #3, family, is not a number or nil")

    local hints = ffi.new("struct addrinfo[1]")
    local servinfo = ffi.new("struct addrinfo *[1]")
    local rc
    local errno
    local ai
    local err

    self._connect_fail_callback = errhandler
    self._connecting = true

    ffi.fill(hints[0], ffi.sizeof(hints[0]))
    hints[0].ai_socktype = SOCK_STREAM
    hints[0].ai_family = family or AF_UNSPEC
    hints[0].ai_protocol = 0

    rc = ffi.C.getaddrinfo(address, tostring(port), hints, servinfo)
    if rc ~= 0 then
        return -1, string.format("Could not resolve hostname '%s': %s",
            address, ffi.C.gai_strerror(rc))
    end

    ffi.gc(servinfo, function (ai) ffi.C.freeaddrinfo(ai[0]) end)

    local ai, err = sockutils.connect_addrinfo(self.socket, servinfo)
    if not ai then
        return -1, err
    end

    self._connect_callback = callback
    self._connect_callback_arg = arg
    self:_add_io_state(ioloop.WRITE)
    return 0
end

--- Read until delimiter, then call callback with recieved data. The callback 
-- recieves the data read as a parameter. Delimiter is plain text, and does 
-- not support Lua patterns. See read_until_pattern for that functionality. 
-- read_until should be used instead of read_until_pattern wherever possible 
-- because of the overhead of doing pattern matching.
-- @param delimiter (String) Delimiter sequence, text or binary.
-- @param callback (Function) Callback function.
-- @param arg Optional argument for callback. If arg is given then it will
-- be the first argument for the callback and the data will be the second.
function iostream.IOStream:read_until(delimiter, callback, arg)
    assert((not self._read_callback), "Already reading.")
    self._read_delimiter = delimiter
    self._read_callback = callback
    self._read_callback_arg = arg
    self._read_scan_offset = 0
    self:_initial_read()
end

--- Read until pattern is matched, then call callback with recieved data. 
-- The callback recieves the data read as a parameter. If you only are
-- doing plain text matching then using read_until is recommended for
-- less overhead.
-- @param pattern (String) Lua pattern string.
-- @param callback (Function) Callback function. 
-- @param arg Optional argument for callback. If arg is given then it will
-- be the first argument for the callback and the data will be the second.
function iostream.IOStream:read_until_pattern(pattern, callback, arg)
    assert(type(pattern) == "string", "argument #1, pattern, is not a string.")
    self._read_callback = callback
    self._read_callback_arg = arg
    self._read_pattern = pattern
    self._read_scan_offset = 0
    self:_initial_read()
end

--- Call callback when we read the given number of bytes.
-- If a streaming_callback argument is given, it will be called with chunks 
-- of data as they become available, and the argument to the final call to 
-- callback will be empty.
-- @param num_bytes (Number) The amount of bytes to read.
-- @param callback (Function) Callback function.
-- @param arg Optional argument for callback. If arg is given then it will
-- be the first argument for the callback and the data will be the second.
-- @param streaming_callback (Function) Optional callback to be called as 
-- chunks become available.
-- @param streaming_arg Optional argument for callback. If arg is given then
-- it will be the first argument for the callback and the data will be the 
-- second.
function iostream.IOStream:read_bytes(num_bytes, callback, arg, 
    streaming_callback, streaming_arg)
    assert((not self._read_callback), "Already reading.")
    assert(type(num_bytes) == 'number', 
        'argument #1, num_bytes, is not a number')
    self._read_bytes = num_bytes
    self._read_callback = callback
    self._read_callback_arg = arg
    self._streaming_callback = streaming_callback
    self._streaming_callback_arg = streaming_arg
    self:_initial_read()
end


--- Reads all data from the socket until it is closed.
-- If a streaming_callback argument is given, it will be called with chunks of
-- data as they become available, and the argument to the final call to 
-- callback will be empty. This method respects the max_buffer_size set in the
-- IOStream instance.
-- @param callback (Function) Callback function.
-- @param arg Optional argument for callback. If arg is given then it will
-- be the first argument for the callback and the data will be the second.
-- @param streaming_callback (Funcion) Optional callback to be called as 
-- chunks become available.
-- @param streaming_arg Optional argument for callback. If arg is given then
-- it will be the first argument for the callback and the data will be the 
-- second.
function iostream.IOStream:read_until_close(callback, arg, streaming_callback, 
    streaming_arg)   
    if self._read_callback then
        error("Already reading.")
    end
    if self:closed() then
        self:_run_callback(callback, arg, 
            self:_consume(self._read_buffer_size))
        return
    end
    self._read_until_close = true
    self._read_callback = callback
    self._read_callback_arg = arg
    self._streaming_callback = streaming_callback
    self._streaming_callback_arg = streaming_arg
    self:_add_io_state(ioloop.READ)
end

--- Write the given data to the stream.
-- If callback is given, we call it when all of the buffered write data has 
-- been successfully written to the stream. If there was previously buffered 
-- write data and an old write callback, that callback is simply overwritten 
-- with this new callback.
-- @param data (String) Data to write to stream.
-- @param callback (Function) Optional callback to call when chunk is flushed.
-- @param arg Optional argument for callback.
function iostream.IOStream:write(data, callback, arg)
    if self._const_write_buffer then 
        error(string.format("\
            Can not perform write when there is a ongoing \
            zero copy write operation. At offset %d of %d bytes", 
            tonumber(self._write_buffer_offset), 
            tonumber(self._const_write_buffer:len())))
    end
    self:_check_closed()
    self._write_buffer:append_luastr_right(data)
    self._write_buffer_size = self._write_buffer_size + data:len()
    self._write_callback = callback
    self._write_callback_arg = arg
    self:_add_io_state(ioloop.WRITE)
    self:_maybe_add_error_listener()
end 

--- Write the given buffer class instance to the stream.
-- @param buf (Buffer class instance).
-- @param callback (Function) Optional callback to call when chunk is flushed.
-- @param arg Optional argument for callback.
function iostream.IOStream:write_buffer(buf, callback, arg)
    if self._const_write_buffer then 
        error(string.format("\
            Can not perform write when there is a ongoing \
            zero copy write operation. At offset %d of %d bytes", 
            tonumber(self._write_buffer_offset), 
            tonumber(self._const_write_buffer:len())))
    end
    self:_check_closed()
    local ptr, sz = buf:get()
    self._write_buffer:append_right(ptr, sz)
    self._write_buffer_size = self._write_buffer_size + sz
    self._write_callback = callback
    self._write_callback_arg = arg
    self:_add_io_state(ioloop.WRITE)
    self:_maybe_add_error_listener()
end

--- Write the given buffer class instance to the stream without
-- copying. This means that this write MUST complete before any other
-- writes can be performed. There is a barrier in place to stop this from 
-- happening. A error is raised if this happens. This method is recommended
-- when you are serving static data, it refrains from copying the contents of 
-- the buffer into its internal buffer, at the cost of not allowing
-- more data being added to the internal buffer before this write is finished.
-- @param buf (Buffer class instance) Will not be modified.
-- @param callback (Function) Optional callback to call when chunk is flushed.
-- @param arg Optional argument for callback.
function iostream.IOStream:write_zero_copy(buf, callback, arg)
    if self._write_buffer_size ~= 0 then
        error(string.format("\
            Can not perform zero copy write when there are \
            unfinished writes in stream. At offset %d of %d bytes. \
            Write buffer size: %d", 
            tonumber(self._write_buffer_offset), 
            tonumber(self._write_buffer:len()),
            self._write_buffer_size))
    end
    self:_check_closed()
    self._const_write_buffer = buf
    self._write_buffer_offset = 0
    self._write_callback = callback
    self._write_callback_arg = arg
    self:_add_io_state(ioloop.WRITE)
    self:_maybe_add_error_listener()
end

--- Are the stream currently being read from? 
-- @return (Boolean) true or false
function iostream.IOStream:reading() 
    return self._read_callback and true or false 
end

--- Are the stream currently being written too.
-- @return (Boolean) true or false
function iostream.IOStream:writing() 
    return self._write_buffer_size ~= 0 or self._const_write_buffer
end

--- Sets the given callback to be called via the :close() method on close.
-- @param callback (Function) Optional callback to call when connection is 
-- closed.
-- @param arg Optional argument for callback.
function iostream.IOStream:set_close_callback(callback, arg)
    self._close_callback = callback
    self._close_callback_arg = arg
end

--- Close this stream and clean up.
-- Call close callback if set.
function iostream.IOStream:close()
    if self.socket then
        --log.devel("[iostream.lua] Closing socket " .. self.socket)
        if self._read_until_close then
            local callback = self._read_callback
            local arg = self._read_callback_arg
            self._read_callback = nil
            self._read_callback_arg = nil
            self._read_until_close = false
            self:_run_callback(callback, arg, 
                self:_consume(self._read_buffer_size))
        end
        if self._state then
            self.io_loop:remove_handler(self.socket)
            self._state = nil
        end
        socket.close(self.socket)
        self.socket = nil
        if self._close_callback and self._pending_callbacks == 0 then
            local callback = self._close_callback
            local arg = self._close_callback_arg
            self._close_callback = nil
            self._close_callback_arg = nil
            self:_run_callback(callback, arg)
        end
    end
end

--- Is the stream closed?
-- @return (Boolean) true or false
function iostream.IOStream:closed()
    if self.socket then
        return false 
    else
        return true
    end
end

--- Initial inline read for read methods.
-- If read is not possible at this time, it is added to IOLoop.
function iostream.IOStream:_initial_read()
    while true do 
        if (self:_read_from_buffer() == true) then
            return
        end
        self:_check_closed()
        if (self:_read_to_buffer() == 0) then
            break
        end
    end
    self:_add_io_state(ioloop.READ)
end

--- Main event handler for the IOStream.
-- @param fd (Number) File descriptor.
-- @param events (Number) Bit mask of available events for given fd.
function iostream.IOStream:_handle_events(fd, events)   
    if not self.socket then 
        -- Connection has been closed. Can not handle events...
        log.warning("got events for closed stream" .. fd)
        return
    end
    -- Handle different events.
    if bitand(events, ioloop.READ) ~= 0 then
        self:_handle_read()
    end
    -- We must check if the socket has been closed after handling
    -- the read!
    if not self.socket then 
        return
    end
    if bitand(events, ioloop.WRITE) ~= 0 then
        if self._connecting then 
            self:_handle_connect()
        end
        self:_handle_write()    
    end
    if not self.socket then 
        return
    end
    if bitand(events, ioloop.ERROR) ~= 0 then
        local rc, err = socket.get_socket_error(self.socket)
        if rc == 0 then
            self.error = err
        end
        -- We may have queued up a user callback in _handle_read or
        -- _handle_write, so don't close the IOStream until those
        -- callbacks have had a chance to run. 
        self.io_loop:add_callback(self.close, self)
        return
    end
    local state = ioloop.ERROR
    if self:reading() then
        state = bitor(state, ioloop.READ)
    end
    if self:writing() then
        state = bitor(state, ioloop.WRITE)
    end
    if state == ioloop.ERROR then
        state = bitor(state, ioloop.READ)
    end
    if state ~= self._state then
        assert(self._state, "no self._state set")
        self._state = state
        self.io_loop:update_handler(self.socket, self._state)
    end
end

--- Error handler for IOStream callbacks.
local function _run_callback_error_handler(err)
    log.error(string.format(
        "[iostream.lua] Error in callback %s. Closing socket.", err))
    log.stacktrace(debug.traceback())
end

local function _run_callback_protected(call)
    -- call[1] : Calling IOStream instance.
    -- call[2] : Callback
    -- call[3] : Callback result
    -- call[4] : Callback argument (userinfo)    
    call[1]._pending_callbacks = call[1]._pending_callbacks - 1
    local success
    if call[4] then
        -- Callback argument. First argument should be this to allow self 
        -- references to be used as argument.
        success = xpcall(
            call[2], 
            _run_callback_error_handler, 
            call[4], 
            call[3])
    else
        success = xpcall(
            call[2], 
            _run_callback_error_handler, 
            call[3])
    end
    if success == false then
        call[1]:close()
    end
end

function iostream.IOStream:_run_callback(callback, arg, data)
    self:_maybe_add_error_listener()
    self._pending_callbacks = self._pending_callbacks + 1
    -- Add callback to IOLoop instead of calling it straight away.
    -- This is to provide a consistent stack growth, while also
    -- yielding to handle other tasks in the IOLoop.
    self.io_loop:add_callback(_run_callback_protected, 
        {self, callback, data, arg})
end

function iostream.IOStream:_maybe_run_close_callback()
    if self:closed() == true and self._close_callback and 
        self._pending_callbacks == 0 then 
        local cb = self._close_callback
        local arg = self._close_callback_arg
        self._close_callback = nil
        self._close_callback_arg = nil
        self:_run_callback(cb, arg)
        self._read_callback = nil
        self._read_callback_arg = nil
        self._write_callback = nil
        self._write_callback_arg = nil
    end
end

function iostream.IOStream:_handle_read()
    self._pending_callbacks = self._pending_callbacks + 1
    while not self:closed() do
        -- Read from socket until we get EWOULDBLOCK or equivalient.
        if self:_read_to_buffer() == 0 then
            break
        end
    end
    self._pending_callbacks = self._pending_callbacks - 1
    if self:_read_from_buffer() == true then
        return
    else
        self:_maybe_run_close_callback()    
    end
end

--- Reads from the socket. Return the data chunk or nil if theres nothing to
-- read, in the case of EWOULDBLOCK or equivalent.
-- @return Chunk of data.
function iostream.IOStream:_read_from_socket()
    local errno
    local sz = tonumber(socket.recv(self.socket, buf, 4096, 0))
    if sz == -1 then
        errno = ffi.errno()
        if errno == EWOULDBLOCK or errno == EAGAIN then
            return nil
        else
            local fd = self.socket
            self:close()
            error(string.format(
                "Error when reading from socket %d. Errno: %d. %s",
                fd,
                errno,
                socket.strerror(errno)))
        end
    end
    if sz == 0 then
        self:close()
        return nil
    end
    return buf, sz
end

--- Read from the socket and append to the read buffer. 
--  @return Amount of bytes appended to self._read_buffer.
function iostream.IOStream:_read_to_buffer()
    local ptr, sz = self:_read_from_socket()
    if not ptr then
        return 0
    end
    self._read_buffer:append_right(ptr, sz)
    self._read_buffer_size = self._read_buffer_size + sz
    if self._read_buffer_size >= self.max_buffer_size then
        log.error('Reached maximum read buffer size')
        self:close()
        return
    end
    return sz
end

--- Get the current read buffer pointer and size.
function iostream.IOStream:_get_buffer_ptr()
    local ptr, sz = self._read_buffer:get()
    ptr = ptr + self._read_buffer_offset
    sz = sz - self._read_buffer_offset
    return ptr, sz
end

--- Attempts to complete the currently pending read from the buffer.
-- @return (Boolean) Returns true if the enqued read was completed, else false.
function iostream.IOStream:_read_from_buffer()
    -- Handle streaming callbacks first.
    if self._streaming_callback ~= nil and self._read_buffer_size ~= 0 then
        local bytes_to_consume = self._read_buffer_size
        if self._read_bytes ~= nil then
            bytes_to_consume = min(self._read_bytes, bytes_to_consume)
            self._read_bytes = self._read_bytes - bytes_to_consume
            self:_run_callback(self._streaming_callback, 
                self._streaming_callback_arg, 
                self:_consume(bytes_to_consume))
        else
            self:_run_callback(self._streaming_callback, 
                self._streaming_callback_arg, 
                self:_consume(bytes_to_consume))
        end
    end
    -- Handle read_bytes.
    if self._read_bytes ~= nil and 
        self._read_buffer_size >= self._read_bytes then
        local num_bytes = self._read_bytes
        local callback = self._read_callback
        local arg = self._read_callback_arg
        self._read_callback = nil
        self._read_callback_arg = nil
        self._streaming_callback = nil
        self._streaming_callback_arg = nil
        self._read_bytes = nil
        self:_run_callback(callback, arg, self:_consume(num_bytes))
        return true
    -- Handle read_until.
    elseif self._read_delimiter ~= nil then        
        if self._read_buffer_size ~= 0 then
            local ptr, sz = self:_get_buffer_ptr()
            local delimiter_sz = self._read_delimiter:len()
            ptr = ptr + self._read_scan_offset
            sz = sz - self._read_scan_offset
            local loc = util.str_find(
                ptr,
                ffi.cast("char *", self._read_delimiter),
                sz,
                delimiter_sz)
            if loc then
                loc = loc - ptr
                local delimiter_end = loc + delimiter_sz
                local callback = self._read_callback
                local arg = self._read_callback_arg
                self._read_callback = nil
                self._read_callback_arg = nil
                self._streaming_callback = nil
                self._streaming_callback_arg = nil
                self._read_delimiter = nil
                self._read_scan_offset = delimiter_end
                if arg then
                    self:_run_callback(callback, 
                        arg, 
                        self:_consume(delimiter_end))
                else
                    self:_run_callback(callback, self:_consume(delimiter_end))
                end
                return true
            end
            self._read_scan_offset = sz
        end
    -- Handle read_until_pattern.
    elseif self._read_pattern ~= nil then
        if self._read_buffer_size ~= 0 then            
            -- Slow buffer to Lua string conversion to support Lua patterns.
            -- Made even worse by a new allocation in self:_consume of a
            -- different size.
            local ptr, sz = self:_get_buffer_ptr()
            local chunk = ffi.string(
                ptr + self._read_scan_offset, 
                sz - self._read_scan_offset)
            local s_start, s_end = chunk:find(self._read_pattern, 1, false)
            if s_start then
                local callback = self._read_callback
                local arg = self._read_callback_arg
                self._read_callback = nil
                self._read_callback_arg = nil
                self._streaming_callback = nil
                self._streaming_callback_arg = nil
                self._read_pattern = nil
                self._read_scan_offset = s_end
                self:_run_callback(callback, arg, self:_consume(s_end))
                return true
            end
            self._read_scan_offset = sz
        end
    end
    return false
end

function iostream.IOStream:_handle_write_nonconst()
    local errno, fd
    local ptr, sz = self._write_buffer:get()
    local buf = ptr + self._write_buffer_offset
    local num_bytes = tonumber(socket.send(
        self.socket, 
        buf, 
        self._write_buffer_size, 
        0))
    if num_bytes == -1 then
        errno = ffi.errno()
        if errno == EWOULDBLOCK or errno == EAGAIN then
            return
        elseif errno == EPIPE or errno == ECONNRESET then
            -- Connection reset. Close the socket.
            fd = self.socket
            self:close()
            log.warning(string.format(
                "Connection closed on fd %d.", 
                fd))
            return
        end
        fd = self.socket                
        self:close()
        error(string.format("Error when writing to fd %d, %s", 
            fd, 
            socket.strerror(errno)))
    end
    if num_bytes == 0 then
        return
    end
    self._write_buffer_offset = self._write_buffer_offset + num_bytes
    self._write_buffer_size = self._write_buffer_size - num_bytes
    if self._write_buffer_size == 0 then
        -- Buffer reached end. Reset offset and size.
        self._write_buffer:clear()
        self._write_buffer_offset = 0
        if self._write_callback then
            -- Current buffer completely flushed.
            local callback = self._write_callback
            local arg = self._write_callback_arg
            self._write_callback = nil
            self._write_callback_arg = nil
            self:_run_callback(callback, arg)
        end
    end
end

function iostream.IOStream:_handle_write_const()
    local errno, fd
    -- The reference is removed once the write is complete.
    local buf, sz = self._const_write_buffer:get()
    -- Pointer will not change while inside this loop, so we do not
    -- have to reget the pointer for every iteration, just recalculate
    -- address and size with new offset.
    local ptr = buf + self._write_buffer_offset
    local _sz = sz - self._write_buffer_offset
    local num_bytes = socket.send(
        self.socket, 
        ptr, 
        _sz, 
        0)
    if num_bytes == -1 then
        errno = ffi.errno()
        if errno == EWOULDBLOCK or errno == EAGAIN then
            return
        elseif errno == EPIPE or errno == ECONNRESET then
            -- Connection reset. Close the socket.
            fd = self.socket
            self:close()
            log.warning(string.format(
                "Connection closed on fd %d.", 
                fd))
            return
        end
        fd = self.socket                
        self:close()
        error(string.format("Error when writing to fd %d, %s", 
            fd, 
            socket.strerror(errno)))
    end
    if num_bytes == 0 then
        return
    end
    self._write_buffer_offset = self._write_buffer_offset + num_bytes
    if sz == self._write_buffer_offset then
        -- Buffer reached end. Remove reference to const write buffer.
        self._write_buffer_offset = 0
        self._const_write_buffer = nil
        if self._write_callback then
            -- Current buffer completely flushed.
            local callback = self._write_callback
            local arg = self._write_callback_arg
            self._write_callback = nil
            self._write_callback_arg = nil
            self:_run_callback(callback, arg)
        end
    end
end

function iostream.IOStream:_handle_write()
    if self._const_write_buffer then
        self:_handle_write_const()
    else
        self:_handle_write_nonconst()
    end
end

--- Add IO state to IOLoop.
-- @param state (Number) IOLoop state to set.
function iostream.IOStream:_add_io_state(state)
    if not self.socket then
        -- Connection has been closed, ignore request.
        return
    end
    if not self._state then
        self._state = bitor(ioloop.ERROR, state)
        self.io_loop:add_handler(self.socket, 
            self._state, 
            self._handle_events, 
            self)
    elseif bitand(self._state, state) == 0 then
        self._state = bitor(self._state, state)
        self.io_loop:update_handler(self.socket, self._state)
    end 
end

function iostream.IOStream:_consume(loc)
    if loc == 0 then
        return ""
    end
    self._read_buffer_size = self._read_buffer_size - loc
    local ptr, sz = self._read_buffer:get()
    local chunk = ffi.string(ptr + self._read_buffer_offset, loc)
    self._read_buffer_offset = self._read_buffer_offset + loc
    if self._read_buffer_offset == sz then
        -- Buffer reached end. Reset offset and size.
        -- We could in theory shrink buffer here but, it is faster
        -- to let it stay as is.
        self._read_buffer:clear()
        self._read_buffer_offset = 0
    end
    return chunk
end

function iostream.IOStream:_check_closed()
    if not self.socket then
        error("Socket operation on closed stream.")
    end
end

function iostream.IOStream:_maybe_add_error_listener()
    if self._state == nil and self._pending_callbacks == 0 then
        if self.socket == nil then
            local callback = self._close_callback
            local arg = self._close_callback_arg
            if callback ~= nil then
                self._close_callback = nil
                self._close_callback_arg = nil
                self:_run_callback(callback, arg)
            end
        else
            self:_add_io_state(ioloop.READ)
        end
    end
end

function iostream.IOStream:_handle_connect()
    local rc, sockerr = socket.get_socket_error(self.socket)
    if rc == -1 then
        error("[iostream.lua] Could not get socket errors, for fd " .. 
            self.socket)
    else
        if sockerr ~= 0 then
            local fd = self.socket
            self:close()
            local strerror = socket.strerror(sockerr)
            if self._connect_fail_callback then
                if self._connect_callback_arg then
                    self._connect_fail_callback(
                        self._connect_callback_arg, 
                        sockerr, 
                        strerror)
                else
                    self._connect_fail_callback(sockerr, strerror)
                end
            end
            error(string.format(
                "[iostream.lua] Connect failed: %s, for fd %d", 
                socket.strerror(sockerr), fd))
        end
    end
    if self._connect_callback then
        local callback = self._connect_callback
        local arg = self._connect_callback_arg
        self._connect_callback = nil
        self._connect_callback_arg = nil
        self:_run_callback(callback, arg)
    end
    self._connecting = false
end

if _G.TURBO_SSL then
--- SSLIOStream, non-blocking SSL sockets using OpenSSL
-- The class is a extention of the IOStream class and uses
-- OpenSSL for its implementation. Obviously a SSL tunnel
-- software is a more optimal approach than this, as there
-- is quite a bit of overhead in handling SSL connections.
-- For this class to be available, the global _G.TURBO_SSL
-- must be set.
iostream.SSLIOStream = class('SSLIOStream', iostream.IOStream)

--- Initialize a new SSLIOStream class instance.
-- @param fd (Number) File descriptor, either open or closed. If closed then, 
-- the IOStream:connect() method can be used to connect.
-- @param ssl_options (Table) SSL options table contains, public and private 
-- keys and a SSL_context pointer.
-- @param io_loop (IOLoop object) IOLoop class instance to use for event 
-- processing. If none is set then the global instance is used, see the 
-- ioloop.instance() function.
-- @param max_buffer_size (Number) The maximum number of bytes that can be 
-- held in internal buffer before flushing must occur. 
-- If none is set, 104857600 are used as default.
function iostream.SSLIOStream:initialize(fd, ssl_options, io_loop, 
    max_buffer_size)
    self._ssl_options = ssl_options
    -- ssl_options should contain keys with values:
    -- "_ssl_ctx" = SSL_CTX pointer created with context functions in
    -- crypto.lua.
    -- "_type" = Optional number, 0 or 1. 0 indicates that the context
    -- is a server context, and 1 indicates a client context.
    -- Other keys may be stored in the table, but are simply ignored.
    self._ssl = nil
    iostream.IOStream.initialize(self, fd, io_loop, max_buffer_size)
    self._ssl_accepting = true
    self._ssl_connect_callback = nil
    self._ssl_connect_callback_arg = arg
    self._server_hostname = nil
end

function iostream.SSLIOStream:connect(address, port, family, verify, callback, 
    errhandler, arg)
    -- We steal the on_connect callback from the caller. And make sure that we 
    -- do handshaking before anything else.
    self._ssl_connect_callback = callback
    self._ssl_connect_errhandler = errhandler
    self._ssl_connect_callback_arg = arg
    self._ssl_hostname = address
    self._ssl_verify = verify
    return iostream.IOStream.connect(self, 
        address, 
        port, 
        family, 
        self._handle_connect, 
        self._connect_errhandler,
        self)
end

function iostream.SSLIOStream:_connect_errhandler()
    if self._ssl_connect_errhandler then
        local errhandler = self._ssl_connect_errhandler
        local arg = self._ssl_connect_callback_arg
        self._ssl_connect_errhandler = nil
        self._ssl_connect_callback_arg = nil
        self._ssl_connect_callback = nil
        errhandler(arg)
    end
end

function iostream.SSLIOStream:_do_ssl_handshake()
    local err = 0
    local errno
    local rc = 0
    local ssl = self._ssl
    local client = self._ssl_options._type == 1

    -- This method might be called multiple times if we recieved EINPROGRESS 
    -- or equaivalent on prior calls. The OpenSSL documentation states that 
    -- SSL_do_handshake should be called again when its needs are satisfied.
    if not ssl then
        ssl = crypto.lib.SSL_new(self._ssl_options._ssl_ctx)
        if ssl == nil then
            err = crypto.lib.ERR_peek_error()
            crypto.lib.ERR_clear_error()
            error(string.format(
                "Could not do SSL handshake. Failed to create SSL*. %s", 
                crypto.ERR_error_string(err)))
        else
            ffi.gc(ssl, crypto.lib.SSL_free)
        end
        if crypto.lib.SSL_set_fd(ssl, self.socket) <= 0 then
            err = crypto.lib.ERR_peek_error()
            crypto.lib.ERR_clear_error()
            error(string.format(
                "Could not do SSL handshake. \
                    Failed to set socket fd to SSL*. %s", 
                crypto.ERR_error_string(err)))
        end
        if client then
            crypto.lib.SSL_set_connect_state(ssl)
        else
            crypto.lib.SSL_set_accept_state(ssl)
        end
        self._ssl = ssl
    end
    rc = crypto.lib.SSL_do_handshake(ssl)
    if rc <= 0 then
        if client and self._ssl_verify then
            local verify_err = crypto.lib.SSL_get_verify_result(ssl)
            if verify_err ~= 0 then
                error(
                    string.format(
                        "SSL certificate chain validation failed: %s",
                        ffi.string(
                            crypto.lib.X509_verify_cert_error_string(
                                verify_err))))
            end
        end
        err = crypto.lib.SSL_get_error(ssl, rc)
        -- In case the socket is O_NONBLOCK break out when we get  
        -- SSL_ERROR_WANT_* or equal syscall return code.
        if err == crypto.SSL_ERROR_WANT_READ or 
            err == crypto.SSL_ERROR_WANT_READ then
            return
        elseif err == crypto.SSL_ERROR_SYSCALL then
            -- Error on socket.
            errno = ffi.errno()
            if errno == EWOULDBLOCK or errno == EINPROGRESS then
                return
            elseif errno ~= 0 then
                local fd = self.socket
                self:close()
                error(
                    string.format("Error when reading from fd %d. \
                        Errno: %d. %s",
                    fd,
                    errno,
                    socket.strerror(errno)))
            else
                -- Popular belief ties this branch to disconnects before  
                -- handshake is completed.
                local fd = self.socket
                self:close()
                error(string.format(
                    "Could not do SSL handshake. Client connection closed.",
                    fd,
                    errno,
                    socket.strerror(errno)))
            end
        elseif err == crypto.SSL_ERROR_SSL then
            err = crypto.lib.ERR_peek_error()
            crypto.lib.ERR_clear_error()
            error(string.format("Could not do SSL handshake. SSL error. %s", 
                crypto.ERR_error_string(err)))
        else
            error(
                string.format(
                    "Could not do SSL handshake. SSL_do_hanshake returned %d", 
                    err))
        end
    else
        if client and self._ssl_verify then
            rc = libtffi.validate_hostname(self._ssl_hostname, ssl)
            if rc ~= crypto.validate.MatchFound then
                error("SSL certficate hostname validation failed, rc " .. 
                    tonumber(rc))
            end
        end
        -- Connection established. Set accepting flag to false and thereby  
        -- allow writes and reads over the socket.
        self._ssl_accepting = false
        if self._ssl_connect_callback then
            local _ssl_connect_callback = self._ssl_connect_callback
            local _ssl_connect_callback_arg = self._ssl_connect_callback_arg
            self._ssl_connect_callback = nil
            self._ssl_connect_callback_arg = nil
            _ssl_connect_callback(_ssl_connect_callback_arg)
        end
    end 
end

function iostream.SSLIOStream:_handle_read()
    if self._ssl_accepting == true then
        self:_do_ssl_handshake()
        return
    end
    iostream.IOStream._handle_read(self)
end

function iostream.SSLIOStream:_handle_connect()
    if self._connecting == true then
        local rc, sockerr = socket.get_socket_error(self.socket)
        if rc == -1 then
            error("[iostream.lua] Could not get socket errors, for fd " .. 
                self.socket)
        else
            if sockerr ~= 0 then
                local fd = self.socket
                self:close()
                local strerror = socket.strerror(sockerr)
                if self._ssl_connect_errhandler then
                    local errhandler = self._ssl_connect_errhandler
                    local arg = self._ssl_connect_callback_arg
                    self._ssl_connect_errhandler = nil
                    self._ssl_connect_callback_arg = nil
                    self._ssl_connect_callback = nil
                    errhandler(arg, sockerr, strerror)
                end
                error(string.format(
                    "[iostream.lua] Connect failed: %s, for fd %d", 
                    socket.strerror(sockerr), 
                    fd))
            end
        end
        self._connecting = false    
    end
    self:_do_ssl_handshake()
end

function iostream.SSLIOStream:_read_from_socket()
    if self._ssl_accepting == true then
        -- If the handshake has not been completed do not allow
        -- any reads to be done...
        return
    end
    local errno
    local err
    local sz = crypto.SSL_read(self._ssl, buf, 4096)
    if sz == -1 then
        err = crypto.SSL_get_error(self._ssl, sz)
        if err == crypto.SSL_ERROR_SYSCALL then
            errno = ffi.errno()
            if errno == EWOULDBLOCK or errno == EAGAIN then
                return
            else
                local fd = self.socket
                self:close()
                error(string.format(
                    "Error when reading from socket %d. Errno: %d. %s",
                    fd,
                    errno,
                    socket.strerror(errno)))
            end
        elseif err == crypto.SSL_ERROR_WANT_READ then
            return
        else
            local fd = self.socket
            local ssl_err = crypto.ERR_get_error()
            local ssl_str_err = crypto.ERR_error_string(ssl_err)
            self:close()
            error(string.format("SSL error. %s",
                ssl_str_err))
        end
    end
    if sz == 0 then
        self:close()
        return
    end
    return buf, sz
end

function iostream.SSLIOStream:_handle_write_nonconst()
    if self._ssl_accepting == true then
        -- If the handshake has not been completed do not allow any writes to
        -- be done.
        return nil
    end

    local ptr = self._write_buffer:get()
    ptr = ptr + self._write_buffer_offset
    local n = crypto.SSL_write(self._ssl, ptr, self._write_buffer_size)
    if n == -1 then
        local err = crypto.SSL_get_error(self._ssl, n)
        if err == crypto.SSL_ERROR_SYSCALL then
            local errno = ffi.errno()
            if errno == EWOULDBLOCK or errno == EAGAIN then
                return
            else
                local fd = self.socket
                self:close()
                error(string.format(
                    "Error when writing to socket %d. Errno: %d. %s",
                    fd,
                    errno,
                    socket.strerror(errno)))
            end
        elseif err == crypto.SSL_ERROR_WANT_WRITE then
            return
        else
            local fd = self.socket
            local ssl_err = crypto.ERR_get_error()
            local ssl_str_err = crypto.ERR_error_string(ssl_err)
            self:close()
            error(string.format("SSL error. %s",
                ssl_str_err))
        end
    end
    if n == 0 then
        return
    end
    self._write_buffer_offset = self._write_buffer_offset + n
    self._write_buffer_size = self._write_buffer_size - n
    if self._write_buffer_size == 0 then
        -- Buffer reached end. Reset offset and size.
        self._write_buffer:clear()
        self._write_buffer_offset = 0
        if self._write_callback then
            -- Current buffer completely flushed.
            local callback = self._write_callback
            local arg = self._write_callback_arg
            self._write_callback = nil
            self._write_callback_arg = nil
            self:_run_callback(callback, arg)
        end
    end
end

function iostream.SSLIOStream:_handle_write_const()
    if self._ssl_accepting == true then
        -- If the handshake has not been completed do not allow any writes to
        -- be done.
        return nil
    end

    local buf, sz = self._const_write_buffer:get()
    buf = buf + self._write_buffer_offset
    sz = sz - self._write_buffer_offset
    local n = crypto.SSL_write(self._ssl, buf, sz)
    if n == -1 then
        local err = crypto.SSL_get_error(self._ssl, n)
        if err == crypto.SSL_ERROR_SYSCALL then
            local errno = ffi.errno()
            if errno == EWOULDBLOCK or errno == EAGAIN then
                return
            else
                local fd = self.socket
                self:close()
                error(string.format(
                    "Error when writing to socket %d. Errno: %d. %s",
                    fd,
                    errno,
                    socket.strerror(errno)))
            end
        elseif err == crypto.SSL_ERROR_WANT_WRITE then
            return
        else
            local fd = self.socket
            local ssl_err = crypto.ERR_get_error()
            local ssl_str_err = crypto.ERR_error_string(ssl_err)
            self:close()
            error(string.format("SSL error. %s",
                ssl_str_err))
        end
    end
    if n == 0 then
        return
    end
    self._write_buffer_offset = self._write_buffer_offset + n
    if sz == self._write_buffer_offset then
        -- Buffer reached end. Remove reference to const write buffer.
        self._write_buffer_offset = 0
        self._const_write_buffer = nil
        if self._write_callback then
            -- Current buffer completely flushed.
            local callback = self._write_callback
            local arg = self._write_callback_arg
            self._write_callback = nil
            self._write_callback_arg = nil
            self:_run_callback(callback, arg)
        end
    end
end
end
return iostream
