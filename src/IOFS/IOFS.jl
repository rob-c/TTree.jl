"""
    TTree.IOFS

Layer 2: the ROOT file container — sources and sinks, keys, directories, the
free-segment list, the streamer info record, and the file header that ties
them together.

This layer knows where bytes live and how big they are; it does not know what
any of them mean. Turning a key's payload into an object is the object layer's
job, reached through the [`register_factory!`](@ref) seam, which is also what
keeps this layer free of a dependency cycle: `TStreamerInfo` is an object, but
the file must be readable before any object is.
"""
module IOFS

using Dates: Dates, DateTime
using Mmap: Mmap
using UUIDs: UUID, uuid4
using XRootD: XrdCl, Storage

using ..Bytes
using ..Bytes: Bytes, KBYTE_COUNT_MASK
using ..Compress
using ..Compress: Compress

export
    # sources and sinks
    AbstractSource,
    AbstractSink,
    pread!,
    pwrite!,
    read_at,
    MemorySource,
    MemorySink,
    MmapSource,
    IOSource,
    FileSink,
    XRootDSource,
    XRootDSink,
    StorageSource,
    open_source,
    open_sink,
    IOError,
    # keys
    Key,
    KEY_VERSION,
    START_BIG_FILE,
    read_key,
    write_key!,
    key_payload,
    key_buffer,
    keylen_for,
    tstring_sizeof,
    is_compressed,
    is_gap,
    is_bigfile,
    # free segments
    FreeSegment,
    segment_sizeof,
    read_free_segment,
    write_free_segment!,
    free_add!,
    free_tail,
    free_bytes,
    # directories
    Directory,
    DIRECTORY_VERSION,
    dir_record_size,
    read_directory_record!,
    write_directory_record!,
    read_keys!,
    keyname,
    decode_namecycle,
    findkey,
    # files
    ROOTFile,
    FILE_BEGIN,
    ROOT_VERSION,
    create,
    allocate!,
    write!,
    put_key!,
    append_key!,
    write_keys!,
    read_file_header!,
    write_file_header!,
    read_object,
    register_factory!,
    factory,
    # streamer info
    StreamerDB,
    streamers,
    read_streamer_info,
    write_streamer_info!,
    record_streamer!

include("source.jl")
include("key.jl")
include("freelist.jl")
include("directory.jl")
include("file.jl")
include("streamers.jl")

end # module IOFS
