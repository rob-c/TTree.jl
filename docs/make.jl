using Documenter
using TTree

makedocs(;
    sitename="TTree.jl",
    # Given outright rather than taken from the git remote, so that the docs
    # build in a checkout that has none — including the first one.
    repo=Documenter.Remotes.GitHub("rob-c", "TTree.jl"),
    modules=[TTree, TTree.Bytes, TTree.Compress, TTree.IOFS, TTree.Objects, TTree.Trees],
    format=Documenter.HTML(;
        prettyurls=Base.get(ENV, "CI", nothing) == "true",
        repolink="https://github.com/rob-c/TTree.jl",
        edit_link="main",
    ),
    pages=[
        "Home" => "index.md",
        "Reading" => "reading.md",
        "Writing" => "writing.md",
        "The format" => "format.md",
        # One page per module rather than one page: together they are three
        # hundred kilobytes of HTML, which is a page nobody can load on a train.
        "API" => [
            "TTree" => "api/ttree.md",
            "Trees" => "api/trees.md",
            "Objects" => "api/objects.md",
            "IOFS" => "api/iofs.md",
            "Compress" => "api/compress.md",
            "Bytes" => "api/bytes.md",
        ],
    ],
    authors="Rob Currie",
    # A docstring that names something no longer there, or a cross-reference
    # that no longer resolves, fails the build rather than passing quietly.
    checkdocs=:exports,
)

deploydocs(; repo="github.com/rob-c/TTree.jl", devbranch="main", push_preview=true)
