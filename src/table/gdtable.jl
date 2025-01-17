"""
    GDTable

Structure representing a grouped `DTable`.
It wraps over a `DTable` object and provides additional information on how the table is grouped.
To represent the grouping a `cols` field is used, which contains the column symbols used for
grouping and an `index`, which allows to effectively lookup the partitions grouped under a single key.
"""
mutable struct GDTable
    dtable::DTable
    cols::Union{Vector{Symbol},Nothing}
    index::Dict
    grouping_function::Union{Function,Nothing}

    GDTable(dtable, cols, index) = GDTable(dtable, cols, index, nothing)
    function GDTable(dtable, cols, index, grouping_function)
        return new(dtable, cols, deepcopy(index), grouping_function)
    end
end

DTable(gd::GDTable) = DTable(gd.dtable.chunks, gd.dtable.tabletype)

fetch(gd::GDTable) = fetch(gd.dtable)
fetch(gd::GDTable, sink) = fetch(gd.dtable, sink)

"""
    grouped_cols(gd::GDTable) -> Vector{Symbol}

Returns the symbols of columns used in the grouping.
In case grouping on a function was performed a `:KEYS` symbol will be returned.
"""
grouped_cols(gd::GDTable) = gd.cols === nothing ? [:KEYS] : gd.cols

"""
    keys(gd::GDTable) -> KeySet

Returns the keys that `gd` is grouped by.
"""
keys(gd::GDTable) = keys(gd.index)

partition(gd::GDTable, key) = partition(gd, gd.index[key])
function partition(gd::GDTable, indices::Vector{UInt})
    return DTable(VTYPE(getindex.(Ref(gd.dtable.chunks), indices)), gd.dtable.tabletype)
end

length(gd::GDTable) = length(keys(gd.index))

iterate(gd::GDTable) = _iterate(gd, iterate(gd.index))
iterate(gd::GDTable, index_iter_state) = _iterate(gd, iterate(gd.index, index_iter_state))

function _iterate(gd::GDTable, it)
    if it !== nothing
        ((key, partition_indices), index_iter_state) = it
        return key => partition(gd, partition_indices), index_iter_state
    end
    return nothing
end

"""
    trim!(gd::GDTable) -> GDTable

Removes empty chunks from `gd` and unused keys from its index.
"""
function trim!(gd::GDTable)
    d = gd.dtable
    check_result = [Dagger.@spawn isnonempty(c) for c in d.chunks]
    results = fetch.(check_result)

    ok_indices = filter(x -> results[x], 1:length(results))
    d.chunks = getindex.(Ref(d.chunks), sort(ok_indices))

    offsets = zeros(UInt, length(results))

    counter = zero(UInt)
    for (i, r) in enumerate(results)
        counter = r ? counter : counter + 1
        offsets[i] = counter
    end

    for key in keys(gd.index)
        ind = gd.index[key]
        filter!(x -> results[x], ind)

        if isempty(ind)
            delete!(gd.index, key)
        else
            gd.index[key] = ind .- getindex.(Ref(offsets), ind)
        end
    end
    return gd
end

"""
    trim(gd::GDTable) -> GDTable

Returns `gd` with empty chunks and keys removed.
"""
trim(gd::GDTable) = trim!(GDTable(DTable(gd), gd.cols, gd.index))

"""
    tabletype!(gd::GDTable)

Provides the type of the underlying table partition and caches it in `gd`.

In case the tabletype cannot be obtained the default return value is `NamedTuple`.
"""
tabletype!(gd::GDTable) = gd.dtable.tabletype = resolve_tabletype(gd.dtable)

"""
    tabletype(gd::GDTable)

Provides the type of the underlying table partition.
Uses the cached tabletype if available.

In case the tabletype cannot be obtained the default return value is `NamedTuple`.
"""
function tabletype(gd::GDTable)
    return gd.dtable.tabletype === nothing ? resolve_tabletype(gd.dtable) : gd.dtable.tabletype
end

show(io::IO, gd::GDTable) = show(io, MIME"text/plain"(), gd)

function show(io::IO, ::MIME"text/plain", gd::GDTable)
    tabletype = if gd.dtable.tabletype === nothing
        "unknown (use `tabletype!(::GDTable)`)"
    else
        gd.dtable.tabletype
    end
    grouped_by_cols = gd.cols === nothing ? string(gd.grouping_function) : grouped_cols(gd)
    println(io, "GDTable with $(nchunks(gd)) partitions and $(length(gd)) keys")
    println(io, "Tabletype: $tabletype")
    println(io, "Grouped by: $grouped_by_cols")

    function keyshow(gd, key)
        if gd.cols === nothing # grouping function is being used
            "Function $(gd.grouping_function) = $key"
        elseif typeof(key) <: NamedTuple # multi column case
            s = ""
            for x in keys(key)
                s *= "$x = $(key[x]), "
            end
            s = s[1:(end - 2)] # remove last comma
            return s
        else # single column case
            "$(gd.cols[1]) = $key"
        end
    end

    function print_group(io, gd, key; prefix="", suffix="") # print a single group
        d = gd[key]
        println(io, "$(prefix)Group$(suffix) ($(length(d)) rows): $(keyshow(gd,key))")
        pretty_table(io, d)
        return nothing
    end

    sorted_keys = sort(collect(keys(gd)))
    if !get(io, :limit, false)
        ctr = 1
        for key in sorted_keys
            print_group(io, gd, key; suffix=" $(ctr)")
            ctr += 1
        end
    else
        fst, lst = first(sorted_keys), last(sorted_keys)
        print_group(io, gd, fst; prefix="First ")
        if fst != lst
            println(io, "⋮")
            print_group(io, gd, lst; prefix="Last ")
        end
    end
    return nothing
end

"""
    getindex(gdt::GDTable, key) -> DTable

Retrieves a `DTable` from `gdt` with rows belonging to the provided grouping key.
"""
function getindex(gdt::GDTable, key)
    ck = convert(keytype(gdt.index), key)
    ck ∉ keys(gdt) && throw(KeyError(ck))
    return partition(gdt, ck)
end

columnnames_svector(gd::GDTable) = columnnames_svector(gd.dtable)

@inline nchunks(gd::GDTable) = length(gd.dtable.chunks)
