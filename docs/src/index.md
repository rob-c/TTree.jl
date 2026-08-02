# TTree.jl

Read and write ROOT files from Julia, with no ROOT installation and nothing
compiled.

The ROOT file format is a container of self-describing records: a header, a
directory of keys, and — for a `TTree` — columns split into independently
compressed baskets. TTree.jl implements that format directly, so a Julia
process can open a file an experiment produced, pull out the two branches it
cares about, and write its own results back in a form ROOT will read.

Remote files come from [XRootD.jl](https://github.com/JuliaHEP/XRootD.jl),
which is likewise pure Julia, so `root://` needs no extra import and no
external client library.

## Installation

TTree.jl is not yet in the general registry.

```julia
using Pkg
Pkg.add(url="https://github.com/rob-c/XRootD.jl", rev="rewrite/0.3-pure-julia")
Pkg.add(url="https://github.com/rob-c/TTree.jl")
```

The first line will not be needed for long: this package is written against
XRootD.jl 0.3, the pure-Julia rewrite, and the registry carries 0.2 for now.

## A first look

```julia
using TTree

TTree.open("events.root") do f
    keys(f)                 # what the file holds
    t = f["Events"]         # a tree
    entries(t)              # how many rows
    array(t, "nMuon")       # one column, as a Julia array
end
```

Writing is the same journey backwards:

```julia
h = TH1F("h", "a histogram", 10, 0.0, 10.0)
push!(h, 1.5)

TTree.create("out.root") do f
    write!(f, "h", h)
end
```

[Reading](reading.md) covers trees, histograms and remote files;
[Writing](writing.md) covers building objects and putting them on a file;
[The format](format.md) covers what is underneath, which is worth knowing when
a file does something unexpected.

## Layers

The package is a stack, and each layer is usable on its own:

| Module | |
|---|---|
| [`TTree.Bytes`](@ref) | ROOT's serialization format as byte codecs |
| [`TTree.Compress`](@ref) | the compression envelope, one block at a time |
| [`TTree.IOFS`](@ref) | the container: sources, keys, directories, headers |
| [`TTree.Objects`](@ref) | ROOT's classes and their streamer descriptions |
| [`TTree.Trees`](@ref) | trees, branches, leaves, baskets |

Read and write are mirror images at every level, so a file this package writes
decodes with the same code that reads one ROOT wrote.

## What is and is not implemented

| | |
|---|---|
| Files, directories, keys, free list | read and write |
| Compression: zlib, LZ4, ZSTD, LZMA | read and write |
| `TTree` / `TNtuple` structure and metadata | read and write |
| Branch values: all numeric leaves, fixed and variable length, strings | read |
| Histograms, profiles, graphs | read and write |
| `TObjString`, `TList`, `THashList`, `TObjArray`, `TArray*` | read and write |
| Streamer info | read and write |
| Object branches (`TLeafElement`, `TLeafObject`) | not yet — `array` says so rather than guessing |
| Creating tree baskets from Julia data | not yet |
| `RNTuple` | no |

## Relation to other packages

[UnROOT.jl](https://github.com/JuliaHEP/UnROOT.jl) is the established Julia
reader and is the more mature choice for reading, including the object branches
this package does not decode yet. TTree.jl is an independent implementation
written to be symmetric — the same byte layer writes what it reads — and to
keep the file container usable by itself.

The format was implemented from ROOT's own documentation and from the files
themselves. [go-hep/groot](https://github.com/go-hep/hep) was consulted as a
description of the format; no code was copied from it.
