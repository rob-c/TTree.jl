# Tags and masks that ROOT's TBuffer uses to frame serialized objects. Names
# match ROOT's own (`TBufferFile.cxx`, `Bytes.h`) so the two can be read side
# by side.

"""
    KBYTE_COUNT_MASK

Set in the high bits of a leading `UInt32` to mark it as a *byte count* rather
than a class tag. ROOT prefixes most streamed objects with
`(nbytes | KBYTE_COUNT_MASK)`, where `nbytes` counts the bytes that follow the
count itself. Absence of this bit is how [`read_header`](@ref) recognises the
older, count-less framing and rewinds.
"""
const KBYTE_COUNT_MASK = 0x40000000

"""
    KBYTE_COUNT_VMASK

The same idea one word narrower. A class streamed without a header — `TObject`
is the one that matters — is preceded by a bare `Int16` version, and this bit
set in it says a four-byte count came first after all, so the version is two
words further on.
"""
const KBYTE_COUNT_VMASK = 0x4000

"""
    KNEW_CLASS_TAG

Class tag meaning "a class name follows, spelled out". Subsequent references to
the same class within one buffer use a back-reference instead — see
[`read_object_any`](@ref).
"""
const KNEW_CLASS_TAG = 0xFFFFFFFF

"""
    KCLASS_MASK

Distinguishes a *class* back-reference from an *object* back-reference: tags
with this bit set point at a previously seen class, tags without it point at a
previously seen object.
"""
const KCLASS_MASK = 0x80000000

"""
    KMAP_OFFSET

ROOT's reference map is 1-based and reserves entry 1 for "self", so a buffer
position `p` is recorded under key `p + KMAP_OFFSET`. Getting this constant
wrong yields back-references that are silently off by two — which decodes as a
neighbouring object rather than an error.
"""
const KMAP_OFFSET = 2

"Tag denoting a null object pointer."
const KNULL_TAG = 0

"""
`TObject::fBits` flag saying the object lives on the C++ heap.

Set by ROOT on every object it reads and masked out again when it writes one:
it describes memory, not the file. This package does the same, so the bit is
never seen on disk.
"""
const KIS_ON_HEAP = 0x01000000

"""
`TObject::fBits` flag marking an object that is never deleted by ROOT.

Like [`KIS_ON_HEAP`](@ref) this is a memory-management flag, and current ROOT
masks it out when writing. Files written before ROOT ~6.30 do carry it, so a
reader must tolerate it even though a writer should not produce it.
"""
const KNOT_DELETED = 0x02000000

"`TObject::fBits` flag marking an object carrying a reference id (`fUniqueID`)."
const KIS_REFERENCED = 1 << 4

"""
    KSTREAMED_MEMBERWISE

Set in a streamed collection's version word when its elements were written
member-wise (all members of field 1, then all of field 2, …) rather than
object-wise. The bit must be stripped before the version is compared against a
class version, and the payload must then be decoded column-wise.
"""
const KSTREAMED_MEMBERWISE = 0x4000
