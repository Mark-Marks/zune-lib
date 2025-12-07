--!strict
--!optimize 2
local random = zune.random

local buf = buffer.create(0)
local ptr = 0

export type function reveal(t: type)
    if t.tag ~= "table" then
        return t
    end

    local tbl_props = t:properties()

    local phantom_data = t:readproperty(types.singleton("__PHANTOM"))
    if phantom_data then
        return reveal(phantom_data)
    end

    local indexer = t:indexer()
    if indexer then
        local new = types.newtable()
        new:setindexer(reveal(indexer.index), reveal(indexer.readresult or indexer.writeresult))
        return new :: any
    end

    local new = types.newtable()
    for key, v in tbl_props do
        local value = v.read or v.write
        new:setproperty(key, reveal(value))
    end
    return new :: any
end

export type Datatype<T> = {
    read length: number,
    read read: () -> T,
    read __PHANTOM: T,
}

export type Schema<T> = {
    read size: number,
    read read: (buffer) -> T,
}

local function schema<S>(schema_datatype: Datatype<S>): () -> Schema<reveal<Datatype<S>>>
    local schema_read = schema_datatype.read

    @native
    local function read(_buf: buffer)
        buf, ptr = _buf, 0
        return schema_read()
    end

    return {
        size = schema_datatype.length,
        read = read,
    } :: any
end

local gen_cache = {}
local function generator(length: number): () -> buffer
    local hit = gen_cache[length]
    if hit then
        return hit
    end

    local prng = random.LuauPcg32.new()
    local f64_max = 2 ^ 24 - 1

    @native
    local function fillf64(buff: buffer, n: number)
        for i = 0, n do
            buffer.writef64(buff, i * 8, prng:nextNumber(0, f64_max))
        end
    end

    local create
    if length % 8 == 0 then
        local counts = length / 8 - 1
        @native
        function create(): buffer
            local buff = buffer.create(length)
            fillf64(buff, counts)
            return buff
        end
    elseif length % 4 == 0 then
        local f64_counts = length // 8 - 1
        local partlen = length * 8
        local i32_counts = ((length - partlen) / 4) - 1
        local i32_max = 2 ^ 31 - 1
        @native
        function create(): buffer
            local buff = buffer.create(length)
            fillf64(buff, f64_counts)
            for i = 0, i32_counts do
                buffer.writei32(buff, partlen + (4 * i), prng:nextInteger(-i32_max, i32_max))
            end
            return buff
        end
    elseif length % 2 == 0 then
        local f64_counts = length // 8 - 1
        local partlen = length * 8
        local u16_counts = ((length - partlen) / 2) - 1
        local u16_max = 2 ^ 16 - 1
        @native
        function create(): buffer
            local buff = buffer.create(length)
            fillf64(buff, f64_counts)
            for i = 0, u16_counts do
                buffer.writei32(buff, partlen + (2 * i), prng:nextInteger(0, u16_max))
            end
            return buff
        end
    else
        local f64_counts = length // 8 - 1
        local partlen = length * 8
        local u8_counts = length - partlen - 1
        local u8_max = 2 ^ 8 - 1
        @native
        function create(): buffer
            local buff = buffer.create(length)
            fillf64(buff, f64_counts)
            for i = 0, u8_counts do
                buffer.writei32(buff, partlen + i, prng:nextInteger(0, u8_max))
            end
            return buff
        end
    end

    gen_cache[length] = create
    return create
end

local datatypes = {}

-- u8
do
    @native
    local function read(): number
        ptr += 1
        return buffer.readu8(buf, ptr - 1)
    end

    datatypes.u8 = {
        length = 1,
        read = read,
    } :: Datatype<number>
end

-- i8
do
    @native
    local function read(): number
        ptr += 1
        return buffer.readi8(buf, ptr - 1)
    end

    datatypes.i8 = {
        length = 1,
        read = read,
    } :: Datatype<number>
end

-- u16
do
    @native
    local function read(): number
        ptr += 2
        return buffer.readu16(buf, ptr - 2)
    end

    datatypes.u16 = {
        length = 2,
        read = read,
    } :: Datatype<number>
end

-- i16
do
    @native
    local function read(): number
        ptr += 2
        return buffer.readi16(buf, ptr - 2)
    end

    datatypes.i16 = {
        length = 2,
        read = read,
    } :: Datatype<number>
end

-- u32
do
    @native
    local function read(): number
        ptr += 4
        return buffer.readu32(buf, ptr - 4)
    end

    datatypes.u32 = {
        length = 4,
        read = read,
    } :: Datatype<number>
end

-- i32
do
    @native
    local function read(): number
        ptr += 4
        return buffer.readi32(buf, ptr - 4)
    end

    datatypes.i32 = {
        length = 4,
        read = read,
    } :: Datatype<number>
end

-- f32
do
    @native
    local function read(): number
        ptr += 4
        return buffer.readf32(buf, ptr - 4)
    end

    datatypes.f32 = {
        length = 4,
        read = read,
    } :: Datatype<number>
end

-- f64
do
    @native
    local function read(): number
        ptr += 8
        return buffer.readf64(buf, ptr - 8)
    end

    datatypes.f64 = {
        length = 8,
        read = read,
    } :: Datatype<number>
end

-- string
do
    local cache = {}

    local function ctor(length: number): Datatype<string>
        local hit = cache[length]
        if hit then
            return hit
        end

        @native
        local function read(): string
            ptr += length
            return buffer.readstring(buf, ptr - length, length)
        end

        local datatype = {
            length = length,
            read = read,
        } :: Datatype<string>
        cache[length] = datatype
        return datatype
    end

    datatypes.str = ctor
end

-- dynamic string
do
    local cache = {}

    local function ctor(length_datatype: Datatype<number>): Datatype<string>
        assert(
            length_datatype == datatypes.u8 or length_datatype == datatypes.u16,
            "Dynamic strings must have an unsigned length datatype."
        )
        local hit = cache[length_datatype]
        if hit then
            return hit
        end

        local read_dynlength = length_datatype.read
        local datatype_len = length_datatype.length
        assert(datatype_len <= 2, "Dynamic strings can't have a larger possible maximum size than u16.")

        local length = 2 ^ (datatype_len * 8) - 1

        @native
        local function read(): string
            local dynlen = read_dynlength()
            ptr += length
            return buffer.readstring(buf, ptr - dynlen, dynlen)
        end

        local datatype = {
            length = length + datatype_len,
            read = read,
        } :: Datatype<string>
        cache[length_datatype] = datatype
        return datatype
    end

    datatypes.dynstr = ctor
end

-- buffer
do
    local cache = {}

    local function ctor(length: number): Datatype<buffer>
        local hit = cache[length]
        if hit then
            return hit
        end

        @native
        local function read(): buffer
            local output = buffer.create(length)
            buffer.copy(output, 0, buf, ptr, length)
            ptr += length
            return output
        end

        local datatype = {
            length = length,
            read = read,
        } :: Datatype<buffer>
        cache[length] = datatype
        return datatype
    end

    datatypes.buf = ctor
end

-- dynamic buffer
do
    local cache = {}

    local function ctor(length_datatype: Datatype<number>): Datatype<buffer>
        assert(
            length_datatype == datatypes.u8 or length_datatype == datatypes.u16,
            "Dynamic buffers must have an unsigned length datatype."
        )
        local hit = cache[length_datatype]
        if hit then
            return hit
        end

        local read_dynlength = length_datatype.read
        local datatype_len = length_datatype.length
        assert(datatype_len <= 2, "Dynamic buffers can't have a larger possible maximum size than u16.")

        local length = 2 ^ (datatype_len * 8) - 1

        @native
        local function read(): buffer
            local dynlen = read_dynlength()
            local output = buffer.create(dynlen)
            buffer.copy(output, 0, buf, ptr, dynlen)
            ptr += length
            return output
        end

        local datatype = {
            length = length + datatype_len,
            read = read,
        } :: Datatype<buffer>
        cache[length_datatype] = datatype
        return datatype
    end

    datatypes.dynbuf = ctor
end

-- vec2
do
    local cache = {}

    local function ctor(position_datatype: Datatype<number>): Datatype<vector>
        local hit = cache[position_datatype]
        if hit then
            return hit
        end
        local read_axis = position_datatype.read

        @native
        local function read(): vector
            local x, y = read_axis(), read_axis()
            return vector.create(x, y)
        end

        local datatype = {
            length = 2 * position_datatype.length,
            read = read,
        } :: Datatype<vector>
        cache[position_datatype] = datatype
        return datatype
    end

    datatypes.vec2 = ctor
end

-- vec3
do
    local cache = {}

    local function ctor(position_datatype: Datatype<number>): Datatype<vector>
        local hit = cache[position_datatype]
        if hit then
            return hit
        end
        local read_axis = position_datatype.read

        @native
        local function read(): vector
            return vector.create(read_axis(), read_axis(), read_axis())
        end

        local datatype = {
            length = 3 * position_datatype.length,
            read = read,
        } :: Datatype<vector>
        cache[position_datatype] = datatype
        return datatype
    end

    datatypes.vec3 = ctor
end

local function ordered_hash(...: any): string
    local list = { ... }
    local list_len = #list

    local output = ""

    for index = 1, list_len do
        output ..= `{tostring(list[index])}\126\002`
    end

    return output
end

-- struct
-- Thanks ardi for some magic (https://github.com/hardlyardi/light/blob/main/src/utils/holy.luau#L3271).
-- I didn't decide to implement the whole codegen thing, but it's still faster.
do
    local cache = {}

    local table_clone = table.clone -- table.clone isn't fastcalled

    local function ctor<Field>(template: { [string]: Datatype<Field> }): Datatype<{ [string]: Field }>
        local size = 0
        local num_keys = 0
        local fieldnames: { string } = {}
        local datatypes: { Datatype<Field> } = {}
        local readers: { () -> Field } = {}

        for fieldname, datatype in template do
            size += datatype.length
            num_keys += 1
            table.insert(fieldnames, fieldname)
            table.insert(datatypes, datatype)
            table.insert(readers, datatype.read)
        end

        local hash = ordered_hash(table.unpack(fieldnames), table.unpack(datatypes))
        local hit = cache[hash]
        if hit then
            return hit
        end

        -- More stable clone, populating string keys on a clone is much faster
        local clone_template = table_clone(template)

        @native
        local function read(): { [string]: Field }
            local output = table_clone(clone_template)
            for index = 1, num_keys do
                local fieldname = fieldnames[index]
                local read = readers[index]
                output[fieldname] = read()
            end
            return output
        end

        local datatype = {
            length = size,
            read = read,
        } :: Datatype<{ [string]: Field }>
        cache[hash] = datatype
        return datatype
    end

    datatypes.struct = ctor :: <Template>(Template) -> Datatype<Template>
end

local table_create = table.create -- table.create isn't fastcalled

-- array
do
    local cache = {}

    local function ctor<Item>(item_datatype: Datatype<Item>, length: number): Datatype<{ Item }>
        local hash = ordered_hash(item_datatype)
        local hit = cache[hash]
        if hit then
            return hit
        end

        local read_item = item_datatype.read

        @native
        local function read(): { Item }
            local output = table_create(length)
            for index = 1, length do
                output[index] = read_item()
            end
            return output
        end

        local datatype = {
            length = length * item_datatype.length,
            read = read,
        } :: Datatype<{ Item }>
        cache[hash] = datatype
        return datatype
    end

    datatypes.array = ctor
end

-- dynamic array
do
    local cache = {}

    local function ctor<Item>(item_datatype: Datatype<Item>, length_datatype: Datatype<number>): Datatype<{ Item }>
        assert(
            length_datatype == datatypes.u8 or length_datatype == datatypes.u16,
            "Dynamic arrays must have an unsigned length datatype."
        )

        local hash = ordered_hash(item_datatype, length_datatype)
        local hit = cache[hash]
        if hit then
            return hit
        end

        local read_item = item_datatype.read
        local read_dynlength = length_datatype.read
        local datatype_len = length_datatype.length
        assert(datatype_len <= 2, "Dynamic arrays can't have a larger possible maximum size than u16.")

        local length = 2 ^ (datatype_len * 8) - 1

        @native
        local function read(): { Item }
            local dynlen = read_dynlength()
            local output = table_create(dynlen)
            for index = 1, dynlen do
                output[index] = read_item()
            end
            ptr += length - dynlen
            return output
        end

        local datatype = {
            length = length + datatype_len,
            read = read,
        } :: Datatype<{ Item }>
        cache[hash] = datatype
        return datatype
    end

    datatypes.dynarray = ctor
end

return {
    datatypes = datatypes,
    schema = schema,
    generator = generator,
}
