--!strict
--!native
--!optimize 2

local mem = setmetatable({}, { __index = zune.mem })

--[=[
    Joins multiple buffers into a new buffer.

    ```luau
    local b = {
        buffer.fromstring("Hello"),
        buffer.fromstring("World!")
    }
    local joined = mem.joinOwned(buffer.fromstring(", "), b)
    print(buffer.tostring(joined)) -- "Hello, World!"
    ```

    @param separator The buffer to join the buffers with.
    @param buffers The buffers to join.
    @return `buffer` The new buffer.
]=]
function mem.joinOwned(separator: buffer?, buffers: { buffer }): buffer
    local size = 0
    local buffers_len = #buffers
    for i = 1, buffers_len, 1 do
        size += buffer.len(buffers[i])
    end
    local separator_len = 0
    if separator then
        separator_len = buffer.len(separator)
        if buffers_len > 1 then
            size += (buffers_len - 1) * separator_len
        end
    end
    local buf = buffer.create(size)
    local offset = 0
    for i = 1, buffers_len, 1 do
        local b = buffers[i]
        local len = buffer.len(b)
        buffer.copy(buf, offset, b, 0, len)
        offset += len
        if separator_len > 0 and i < buffers_len then
            buffer.copy(buf, offset, separator :: buffer, 0, separator_len)
            offset += separator_len
        end
    end
    return buf
end

return mem
