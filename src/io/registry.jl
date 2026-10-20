# One format registry for file formats (ADR-0004 rule 9, CF-016). Package extensions register
# from their `__init__`; the core keeps one generic error for an unknown format.

struct FormatEntry
    source::Any        # (path; kw...) -> Source
    sink::Any          # (path; kw...) -> Sink
    extensions::Vector{String}
end

const _FORMATS = Dict{Symbol, FormatEntry}()
const _EXTENSIONS = Dict{String, Symbol}()
const _REGISTRY_LOCK = ReentrantLock()

_normext(e::AbstractString) = lowercase(startswith(e, ".") ? String(e) : "." * e)

"""
    register_format!(key::Symbol; source, sink, extensions = String[])

Register a file format under `key` (ADR-0004 rule 9, CF-016). `source(path; kw...)` must return a
[`Source`](@ref) and `sink(path; kw...)` a [`Sink`](@ref). `extensions` (like `[".parquet"]`)
are what `format = :auto` recognizes. A package extension calls this from its `__init__`.

Registering an already-registered `key`, or an extension another key already claims, raises an
`ArgumentError`; an alternative implementation uses a distinct key (e.g. `:parquet_duckdb`)
chosen with an explicit `format =`.
"""
function register_format!(key::Symbol; source, sink, extensions = String[])
    exts = String[_normext(e) for e in extensions]
    lock(_REGISTRY_LOCK) do
        haskey(_FORMATS, key) && throw(ArgumentError("format $(repr(key)) is already registered"))
        for e in exts
            haskey(_EXTENSIONS, e) &&
                throw(ArgumentError("extension $(repr(e)) is already registered for format $(repr(_EXTENSIONS[e]))"))
        end
        _FORMATS[key] = FormatEntry(source, sink, exts)
        for e in exts
            _EXTENSIONS[e] = key
        end
    end
    return key
end

# Built-in formats are (re)registered from `__init__`, replacing any earlier entry.
function _register_builtin!(key::Symbol; source, sink, extensions)
    lock(_REGISTRY_LOCK) do
        old = get(_FORMATS, key, nothing)
        old === nothing || foreach(e -> delete!(_EXTENSIONS, e), old.extensions)
        delete!(_FORMATS, key)
    end
    return register_format!(key; source, sink, extensions)
end

"""
    registered_formats() -> Dict{Symbol, Vector{String}}

The registered format keys and their file extensions.
"""
registered_formats() = lock(() -> Dict(k => copy(v.extensions) for (k, v) in _FORMATS), _REGISTRY_LOCK)

"`format_for(path)`: the format key registered for `path`'s extension, or `nothing`."
function format_for(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    return lock(() -> get(_EXTENSIONS, ext, nothing), _REGISTRY_LOCK)
end

_unknown(what) = throw(ArgumentError("no reader/writer registered for `$what`; load the package that provides it"))

function _entry(path::AbstractString, format::Symbol)
    if format === :auto
        key = format_for(path)
        if key === nothing
            ext = splitext(path)[2]
            _unknown(isempty(ext) ? basename(path) : ext)
        end
    else
        key = format
    end
    e = lock(() -> get(_FORMATS, key, nothing), _REGISTRY_LOCK)
    e === nothing && _unknown(repr(key))
    return e
end

"""
    scan_file(path; format = :auto, kw...) -> Source

The [`Source`](@ref) for the file at `path`, through the format registry (CF-016). `format =
:auto` picks the format from the extension (`.arrow`, `.feather`, `.ipc`, `.arrows`, `.csv`,
`.tsv`; `.parquet` once `Parquet2` is loaded). `kw` are format options (PROVISIONAL). A verb
applied to the source starts a lazy query (`scan_file(path) |> filter(c.x .> 1) |> collect`),
and `collect(scan_file(path))` reads it through the lazy engine; `lazy(scan_file(path))` is the
same query with no verbs.
"""
scan_file(path::AbstractString; format::Symbol = :auto, kw...) = _entry(path, format).source(path; kw...)

"""
    read_file(path; format = :auto, kw...) -> Frame

Read the whole file at `path` into a frame: [`scan_file`](@ref), then every partition in order,
concatenated.
"""
read_file(path::AbstractString; format::Symbol = :auto, kw...) = read_source(scan_file(path; format, kw...))

"""
    write_file(x, path; format = :auto, kw...) -> path

Write `x` (any Tables.jl table, or a [`Source`](@ref)) to `path` through the format's
[`Sink`](@ref) (CF-016). The built-in file sinks commit atomically: they write a temporary file
in the same directory and rename it when done; on any error it is deleted.
"""
function write_file(x, path::AbstractString; format::Symbol = :auto, kw...)
    sink = _entry(path, format).sink(path; kw...)
    write_source(sink, x)
    return path
end
