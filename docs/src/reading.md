# Reading

## Opening a file

```@docs
TTree.open
```

A file is a directory of keys, and the keys are what `keys` returns:

```julia
TTree.open("dirs.root") do f
    keys(f)                       # ["dir1", "dir2", "dir3"]
    f["dir1"]                     # Directory("dir1", "dir1", 1 keys)
    f["dir1/dir11/h1"]            # TH1F("h1", 100 bins, 5.0 entries)
end
```

Subdirectories are addressed by path. A key names an object; asking for it
reads and decodes it. A class this package does not know is skipped rather than
guessed at, using the byte count ROOT wrote in front of it — which is what lets
a file full of experiment-specific classes still be opened and navigated.

The two-argument form closes the file when the block returns, including on
error. The one-argument form returns the file and leaves closing to you.

### Remote files

Local paths, `root://`, `roots://`, `http(s)://`, `dav(s)://` and `s3://` URLs
all open the same way:

```julia
TTree.open("root://eospublic.cern.ch//eos/opendata/.../file.root") do f
    array(f["Events"], "nMuon")
end
```

Reads are ranged, so opening a file over the network fetches its header and its
keys, not its contents, and reading one branch fetches that branch's baskets
and nothing else. Keyword arguments are passed through to the source, which is
where credentials go.

## Trees

```@docs
TTree.Trees.array
```

The shape follows the leaf. Given the tree fixture that ships with the package:

```julia
TTree.open("trees.root") do f
    t = f["t"]
    entries(t)                    # 100

    array(t, "i32")               # 100-element Vector{Int32}
    array(t, "arr")               # 3×100 Matrix{Float64}
    array(t, "sli")               # 100-element Vector{Vector{Float64}}
    array(t, "str")               # 100-element Vector{String}
end
```

A fixed-length leaf gives a matrix whose columns are entries — x fastest, as
ROOT stores it. A variable-length leaf is counted by a leaf that usually lives
in a branch of its own, so reading one column can mean reading two; that is
handled for you.

A branch with several leaves stores them interleaved, and each is named:

```julia
b = t["pair"]
array(b, "b")                     # the branch's second leaf...
array(b, "a")                     # ...and its first
array(b)                          # ArgumentError: name one of "b", "a"
```

### Streaming

```@docs
TTree.Trees.eachchunk
```

`array` materialises a whole column. A column too large for that is folded over
a basket at a time:

```julia
total = 0.0
for v in eachchunk(t, "energy")
    total += sum(v)
end
```

Each chunk is shaped the way `array` shapes the whole branch, and concatenating
them gives back exactly what `array` would have returned.

For the records underneath — the compressed payload as it sits on the file —
there is [`eachbasket`](@ref TTree.Trees.eachbasket).

## Histograms and graphs

```julia
TTree.open("hists.root") do f
    h = f["h1f"]                  # TH1F("h1f", 10 bins, 58.0 entries)

    nbins(h)                      # 10
    bincontents(h)                # 12 values: underflow, 10 bins, overflow
    binerrors(h)
    binedges(h)                   # 11 edges
    bincenters(h)
    entries(h)                    # 58.0
end
```

The cell array includes the underflow and overflow bins, which is how ROOT
stores it: `bincontents(h)[1]` is the underflow and `bincontents(h)[end]` the
overflow. A 2-D or 3-D histogram gives a matrix or a 3-array of the same kind,
x fastest.

Contents come back with ROOT's meaning rather than ROOT's storage. A
[`TProfile`](@ref TTree.Objects.TProfile) keeps three numbers per bin — the sum
of weights, of `w·y` and of `w·y²` — and its contents are the mean of `y`, so
[`bincontents`](@ref TTree.Objects.bincontents) divides and
[`binerrors`](@ref TTree.Objects.binerrors) reproduces all four of ROOT's error
modes. [`binentries`](@ref TTree.Objects.binentries) and
[`bineffentries`](@ref TTree.Objects.bineffentries) give the counts underneath.

Graphs answer the same questions whatever their class:

```julia
x, y = points(g)
lo, hi = xerrors(g)               # zeros for a plain TGraph
lo, hi = yerrors(g)
```

## Class descriptions

Every ROOT file carries the layout of the classes it contains, which is how a
reader written years later can still decode it:

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
and `TH1` v3 through v8 without a special case per version. See
[The format](format.md).
