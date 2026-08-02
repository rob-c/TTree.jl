# ROOT's streamer type codes.
#
# Every `TStreamerElement` carries one of these in `fType`, and it is what
# decides how the member's bytes are read. The numbering is fixed by the file
# format — it appears verbatim in every `.root` file — so these are constants,
# not an enum whose values could drift.
#
# The structure worth knowing: base codes 1..19 are the scalar types; adding
# `RMETA_OFFSET_L` (20) makes it a fixed-size array of that type, and adding
# `RMETA_OFFSET_P` (40) makes it a pointer to a variable-length one.

const RMETA_BASE = Int32(0)
const RMETA_CHAR = Int32(1)
const RMETA_SHORT = Int32(2)
const RMETA_INT = Int32(3)
const RMETA_LONG = Int32(4)
const RMETA_FLOAT = Int32(5)
const RMETA_COUNTER = Int32(6)
const RMETA_CHARSTAR = Int32(7)
const RMETA_DOUBLE = Int32(8)
const RMETA_DOUBLE32 = Int32(9)
const RMETA_LEGACY_CHAR = Int32(10)
const RMETA_UCHAR = Int32(11)
const RMETA_USHORT = Int32(12)
const RMETA_UINT = Int32(13)
const RMETA_ULONG = Int32(14)
const RMETA_BITS = Int32(15)
const RMETA_LONG64 = Int32(16)
const RMETA_ULONG64 = Int32(17)
const RMETA_BOOL = Int32(18)
const RMETA_FLOAT16 = Int32(19)

"Added to a scalar code to denote a fixed-size array of it."
const RMETA_OFFSET_L = Int32(20)

"Added to a scalar code to denote a pointer to a variable-length array of it."
const RMETA_OFFSET_P = Int32(40)

const RMETA_OBJECT = Int32(61)
const RMETA_ANY = Int32(62)
const RMETA_OBJECTP = Int32(63)
const RMETA_OBJECT_P = Int32(64)
const RMETA_TSTRING = Int32(65)
const RMETA_TOBJECT = Int32(66)
const RMETA_TNAMED = Int32(67)
const RMETA_ANYP = Int32(68)
const RMETA_ANY_P = Int32(69)
const RMETA_ANY_P_NO_VT = Int32(70)
const RMETA_STLP = Int32(71)

const RMETA_SKIP = Int32(100)
const RMETA_SKIP_L = Int32(120)
const RMETA_SKIP_P = Int32(140)

const RMETA_CONV = Int32(200)
const RMETA_CONV_L = Int32(220)
const RMETA_CONV_P = Int32(240)

const RMETA_STL = Int32(300)
const RMETA_STLSTRING = Int32(365)

const RMETA_STREAMER = Int32(500)
const RMETA_STREAM_LOOP = Int32(501)

const RMETA_CACHE = Int32(600)
const RMETA_ARTIFICIAL = Int32(1000)
const RMETA_CACHE_NEW = Int32(1001)
const RMETA_CACHE_DELETE = Int32(1002)
const RMETA_MISSING = Int32(99999)

# STL container kinds, as stored in a TStreamerSTL's `fSTLtype`. The order is
# fixed by ROOT's ESTLType and cannot be rearranged: files carry the values.
const ESTL_NONE = Int32(0)
const ESTL_VECTOR = Int32(1)
const ESTL_LIST = Int32(2)
const ESTL_DEQUE = Int32(3)
const ESTL_MAP = Int32(4)
const ESTL_MULTIMAP = Int32(5)
const ESTL_SET = Int32(6)
const ESTL_MULTISET = Int32(7)
const ESTL_BITSET = Int32(8)
const ESTL_FORWARD_LIST = Int32(9)
const ESTL_UNORDERED_SET = Int32(10)
const ESTL_UNORDERED_MULTISET = Int32(11)
const ESTL_UNORDERED_MAP = Int32(12)
const ESTL_UNORDERED_MULTIMAP = Int32(13)
const ESTL_ANY = Int32(300)
const ESTL_STRING = Int32(365)

"""
    julia_type(code) -> Union{DataType,Nothing}

The Julia type corresponding to an `rmeta` scalar code, or `nothing` for a code
that does not describe a scalar.

`Long_t` maps to `Int64`: ROOT streams it as eight bytes regardless of the
platform's `long`, so the on-disk width is unambiguous even though the C++ type
is not.
"""
function julia_type(code::Integer)
    c = Int32(code)
    c == RMETA_BOOL && return Bool
    c == RMETA_CHAR && return Int8
    c == RMETA_LEGACY_CHAR && return Int8
    c == RMETA_UCHAR && return UInt8
    c == RMETA_SHORT && return Int16
    c == RMETA_USHORT && return UInt16
    c == RMETA_INT && return Int32
    c == RMETA_COUNTER && return Int32
    c == RMETA_BITS && return UInt32
    c == RMETA_UINT && return UInt32
    c == RMETA_LONG && return Int64
    c == RMETA_LONG64 && return Int64
    c == RMETA_ULONG && return UInt64
    c == RMETA_ULONG64 && return UInt64
    c == RMETA_FLOAT && return Float32
    c == RMETA_FLOAT16 && return Float32
    c == RMETA_DOUBLE && return Float64
    c == RMETA_DOUBLE32 && return Float64
    return nothing
end

"""
    base_type(code) -> Int32

Strip an array or pointer offset from a streamer code, leaving the scalar type
underneath.
"""
function base_type(code::Integer)
    c = Int32(code)
    RMETA_OFFSET_P < c < RMETA_OFFSET_P + RMETA_OFFSET_L && return c - RMETA_OFFSET_P
    RMETA_OFFSET_L < c < RMETA_OFFSET_P && return c - RMETA_OFFSET_L
    return c
end
