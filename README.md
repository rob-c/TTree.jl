# TTree.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://rob-c.github.io/TTree.jl/dev/)
[![Build Status](https://github.com/rob-c/TTree.jl/workflows/CI/badge.svg)](https://github.com/rob-c/TTree.jl/actions)
[![License](https://img.shields.io/badge/license-LGPL-blue.svg)](LICENSE)

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

## Getting started

### Reading a tree

```julia
using TTree

TTree.open("chain.flat.1.root") do f
    keys(f)                      # ["tree"]

    t = f["tree"]                # TTree("tree", 5 entries, 35 branches)
    entries(t)                   # 5

    array(t, "F64")              # 5-element Vector{Float64}
    array(t, "ArrI32")           # 10×5 Matrix{Int32}
    array(t, "SliI32")           # 5-element Vector{Vector{Int32}}
    array(t, "Str")              # 5-element Vector{String}
end
```

The shape follows the leaf: a scalar branch gives a vector, a fixed-length
array gives a matrix whose columns are entries, a variable-length array gives a
vector of vectors, and a character branch gives strings. Only the baskets of
the branch asked for are read.

A branch too large to materialise is folded over a basket at a time, each chunk
shaped the way `array` shapes the whole branch:

```julia
total = 0.0
for v in eachchunk(t, "F64")
    total += sum(v)
end
```

Subdirectories are addressed by path:

```julia
TTree.open("dirs.root") do f
    f["dir1/dir11/h1"]           # TH1F("h1", 100 bins, 5.0 entries)
end
```

### Remote files

Local paths, `root://`, `http(s)://`, `dav(s)://` and `s3://` URLs all open the
same way, and remote reads are ranged — opening a file over the network fetches
its header and its keys, not its contents.

```julia
TTree.open("root://eospublic.cern.ch//eos/opendata/.../file.root") do f
    array(f["Events"], "nMuon")
end
```

Keyword arguments are passed through to the source, which is where credentials
go.

### Histograms and graphs

```julia
TTree.open("hists.root") do f
    h = f["h1f"]                 # TH1F("h1f", 10 bins, 58.0 entries)

    nbins(h)                     # 10
    bincontents(h)               # 12 values: underflow, 10 bins, overflow
    binerrors(h)
    binedges(h)                  # 11 edges
    entries(h)                   # 58.0

    x, y = points(f["tgae"])
    lo, hi = yerrors(f["tgae"])  # both sides, whatever the graph class
end
```

`TH1`, `TH2`, `TH3` in all six element types, `TProfile`, `TProfile2D`,
`TGraph`, `TGraphErrors` and `TGraphAsymmErrors` are read, written and built
from Julia. Bin contents come back with ROOT's meaning, not ROOT's storage: a
profile divides by its per-bin entry count and reproduces all four of ROOT's
error modes.

### Writing

```julia
h = TH1F("h", "a histogram", 10, 0.0, 10.0)
push!(h, 1.5)
push!(h, 2.5, 2.0)               # with a weight

g = TGraph("g", "a graph", [1.0, 2.0, 3.0], [1.0, 4.0, 9.0])

TTree.create("out.root") do f
    write!(f, "h", h)
    write!(f, "g", g)
    write!(f, "s", TObjString("hello"))
end
```

The file that comes out is an ordinary ROOT file: header, key list, streamer
info record and free list, compressed with the same codecs ROOT uses (zlib,
LZ4, ZSTD, LZMA — `compression` on `create` sets which).

### Class descriptions

Every ROOT file carries the layout of the classes it contains, which is how a
reader written years later can still decode it. That record is readable
directly:

```julia
TTree.open("graphs.root") do f
    describe(streamers(f)["TGraph"])
end
```

```
StreamerInfo for "TGraph" version=4
  BASE    TNamed      type= 67  size=  0  The basis for a named object (name, title)
  BASE    TAttLine    type=  0  size=  0  Line attributes
  ...
  int     fNpoints    type=  6  size=  4  Number of points <= fMaxSize
  double* fX          type= 48  size=  8  [fNpoints] array of X points
```

Decoding is driven by that description whenever the file's own is the more
specific one, which is what lets a single reader handle `TAxis` v6 through v10
and `TH1` v3 through v8 without a special case per version.

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

A tree read from a file can be re-encoded byte for byte, but writing a tree
whose baskets live in a *different* file is not supported yet: the metadata
would be written and the basket offsets would point into the file it came from.

## Layers

The package is a stack, and each layer is usable on its own:

| Module | |
|---|---|
| `TTree.Bytes` | ROOT's serialization format as byte codecs |
| `TTree.Compress` | the compression envelope, one block at a time |
| `TTree.IOFS` | the container: sources, keys, directories, headers |
| `TTree.Objects` | ROOT's classes and their streamer descriptions |
| `TTree.Trees` | trees, branches, leaves, baskets |

Read and write are mirror images at every level, so a file this package writes
decodes with the same code that reads one ROOT wrote — which is the property
the tests lean on hardest.

## Testing

```julia
using Pkg
Pkg.test("TTree")
```

The tests that check this package against ROOT read a corpus of files that is
not shipped here: the [go-hep/groot](https://github.com/go-hep/hep) test data,
which already collects the format's awkward cases. Point `TTREE_TESTDATA` at
that directory to run them; without it they are skipped, loudly, and the rest
of the suite still runs.

What ROOT says about those files *is* checked in, under `test/data/`, so the
comparison needs ROOT no more than the package does. The generators that
produced it live in `dev/` and are the only thing here that wants a ROOT
installation.

## Relation to other packages

[UnROOT.jl](https://github.com/JuliaHEP/UnROOT.jl) is the established Julia
reader and is the more mature choice for reading, including the object branches
this package does not decode yet. TTree.jl is an independent implementation
written to be symmetric — the same byte layer writes what it reads — and to
keep the file container usable by itself.

The format was implemented from ROOT's own documentation and from the files
themselves. [go-hep/groot](https://github.com/go-hep/hep) was consulted as a
description of the format; no code was copied from it.

## License

LGPL-3.0, the same as XRootD.jl.
