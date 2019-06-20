using MacroTools

 # splitarg produces a tuple for each arg of the form (arg_name, arg_type, slurp, default)
_arg_name(arg_tup) = arg_tup[1]
_arg_type(arg_tup) = arg_tup[2]
_arg_slurp(arg_tup) = arg_tup[3]
_arg_default(arg_tup) = arg_tup[4]

function _collect_exports(exprs)
    # each item in exprs is either a single symbol, or an expression mapping
    # one symbol to another, e.g., [:foo, :bar, :(:baz => :my_baz)]. We peel
    # out the symbols to create a list of pairs.
    exports = []
    # @info "_collect_exports: $exprs"

    for expr in exprs
        if (@capture(expr, name_ => expname_) || @capture(expr, name_)) &&
            (name isa Symbol && (expname === nothing || expname isa Symbol))
            push!(exports, name => @or(expname, name))
        else
            error("Elements of exports list must Symbols or Pair{Symbol, Symbol}, got $expr")
        end 
    end

    # @info "returning $exports"
    return exports
end

const NumericArray = Array{T, N} where {T <: Number, N}

function _collect_bindings(exprs)
    bindings = []
    # @info "_collect_bindings: $exprs"

    for expr in exprs
        if @capture(expr, name_ => val_) && name isa Symbol &&
            (val isa Symbol || val isa Number || val.head in (:vcat, :hcat, :vect))
            push!(bindings, name => val)
        else
            error("Elements of bindings list must Pair{Symbol, Symbol} or Pair{Symbol, Number or Array of Number} got $expr")
        end 
    end

    # @info "returning $bindings"
    return bindings
end

function _subcomp(args, kwargs)
    # splitarg produces a tuple for each arg of the form (arg_name, arg_type, slurp, default)
    arg_tups = map(splitarg, args)

    if kwargs === nothing
        # If a ";" was not used to separate kwargs, move any kwargs from args.
        kwarg_tups = filter(tup -> _arg_default(tup) !== nothing, arg_tups)
        arg_tups   = filter(tup -> _arg_default(tup) === nothing, arg_tups)
    else
        kwarg_tups = map(splitarg, kwargs)
    end

    if 1 > length(arg_tups) > 2
        @error "component() must have one or two non-keyword values"
    end

    arg1 = _arg_name(arg_tups[1])
    alias = length(arg_tups) == 2 ? _arg_name(args_tups[2]) : nothing

    cmodule = nothing
    if ! (@capture(arg1, cmodule_.cname_) || @capture(arg1, cname_Symbol))
        error("Component name must be a Module.name expression or a symbol, got $arg1")
    end

    valid_kws = (:exports, :bindings)    # valid keyword args to the component() psuedo-function
    kw = Dict([key => [] for key in valid_kws])

    for (arg_name, arg_type, slurp, default) in kwarg_tups
        if arg_name in valid_kws
            if default isa Expr && hasmethod(Base.iterate, (typeof(default.args),))
                append!(kw[arg_name], default.args)
            else
                @error "Value of $arg_name argument must be iterable"
            end
        else
            @error "Unknown keyword $arg_name; valid keywords are $valid_kws"
        end
    end

    exports  = _collect_exports(kw[:exports])
    bindings = _collect_bindings(kw[:bindings])
    return SubComponent(cmodule, cname, alias, exports, bindings)
end

# Convert an expr like `a.b.c.d` to `[:a, :b, :c, :d]`
function _parse_dotted_symbols(expr)
    global Args = expr
    syms = Symbol[]

    ex = expr
    while @capture(ex, left_.right_) && right isa Symbol
        push!(syms, right)
        ex = left
    end

    if ex isa Symbol
        push!(syms, ex)
    else
        error("Expected Symbol or Symbol.Symbol..., got $expr")
    end

    syms = reverse(syms)
    var_or_par = pop!(syms)
    return ComponentPath(syms), var_or_par
end

function _ns_params(comp::AbstractComponentDef)
    filter(pair -> pair.second isa Vector{ParameterDefReference}, comp.namespace)
end

function import_params(comp::AbstractCompositeComponentDef)
    # nothing to do if there are no sub-components
    length(comp.comps_dict) == 0 && return

    # grab the already-imported items from the namespace; create a reverse-lookup map
    d = Dict()
    for (local_name, param_refs) in _ns_params(comp)
        for ref in param_refs
            d[(ref.comp_path, ref.name)] = local_name
        end
    end

    @info "import_params: reverse lookup: $d"

    # Iterate over all sub-components and import all params not already referenced (usually renamed)
    for (comp_name, sub_comp) in comp.comps_dict
        path = sub_comp.comp_path
        @info "  path: $path"
        for (local_name, param_refs) in _ns_params(sub_comp)
            for ref in param_refs
                if ! haskey(d, (ref.comp_path, ref.name))
                    comp[local_name] = ref   # import it
                end
            end
        end
    end
end

"""
    defcomposite(cc_name::Symbol, ex::Expr)

Define a Mimi CompositeComponent `cc_name` with the expressions in `ex`.  Expressions
are all variations on `component(...)`, which adds a component to the composite. The
calling signature for `component()` processed herein is:

    component(comp_name, local_name;
              exports=[list of symbols or Pair{Symbol,Symbol}],
              bindings=[list Pair{Symbol, Symbol or Number or Array of Numbers}])

In this macro, the vector of symbols to export is expressed without the `:`, e.g.,
`exports=[var_1, var_2 => export_name, param_1])`. The names must be variable or 
parameter names exported to the composite component being added by its sub-components.

Bindings are expressed as a vector of `Pair` objects, where the first element of the
pair is the name (again, without the `:` prefix) representing a parameter in the component
being added, and the second element is either a numeric constant, a matrix of the
appropriate shape, or the name of a variable in another component. The variable name
is expressed as the component id (which may be prefixed by a module, e.g., `Mimi.adder`)
followed by a `.` and the variable name in that component. So the form is either
`modname.compname.varname` or `compname.varname`, which must be known in the current module.

Unlike leaf components, composite components do not have user-defined `init` or `run_timestep`
functions; these are defined internally to iterate over constituent components and call the
associated method on each.
"""
macro defcomposite(cc_name, ex)
    # @info "defining composite $cc_name in module $(fullname(__module__))"
    
    @capture(ex, elements__)
    comps = SubComponent[]
    imports = []
    conns = []

    for elt in elements
        # @info "parsing $elt"; dump(elt)

        if @capture(elt, (component(args__; kwargs__) | component(args__)))
            push!(comps, _subcomp(args, kwargs))

        # distinguish imports, e.g., :(EXP_VAR = CHILD_COMP1.COMP2.VAR3),
        #    from connections, e.g., :(COMP1.PAR2 = COMP2.COMP5.VAR2)

        # elseif elt.head == :tuple && length(elt.args) > 0 && @capture(elt.args[1], left_ = right_) && left isa Symbol
        #     # Aliasing a local name to several parameters at once is possible using an expr like
        #     # :(EXP_PAR1 = CHILD_COMP1.PAR2, CHILD_COMP2.PAR2, CHILD_COMP3.PAR5, CHILD_COMP3.PAR6)
        #     # Note that this parses as a tuple expression with first element being `EXP_PAR1 = CHILD_COMP1`.
        #     # Here we parse everything on the right side, at once using broadcasting and add the initial
        #     # component (immediately after "=") to the list, and then store a Vector of param refs.
        #     args = [right, elt.args[2:end]...]
        #     vars_pars = _parse_dotted_symbols.(args)
        #     @info "import as $left = $vars_pars"
        #     push!(imports, (left, vars_pars))

        elseif @capture(elt, left_ = right_)

            if left isa Symbol # simple import case
                # Save a singletons as a 1-element Vector for consistency with multiple linked params
                var_par = right.head == :tuple ? _parse_dotted_symbols.(right.args) : [_parse_dotted_symbols(right)]
                push!(imports, (left, var_par))
                @info "import as $left = $var_par"
                
            # note that `comp_Symbol.name_Symbol` failed; bug in MacroTools?
            elseif @capture(left, comp_.name_) && comp isa Symbol && name isa Symbol # simple connection case
                src = _parse_dotted_symbols(right)
                dst = _parse_dotted_symbols(left)
                tup = (dst, src)
                push!(conns, tup)
                @info "connection: $dst = $src"

            else
                error("Unrecognized expression on left hand side of '=' in @defcomposite: $elt")
            end
        else
            error("Unrecognized element in @defcomposite: $elt")
        end
    end

    # TBD: use fullname(__module__) to get "path" to module, as tuple of Symbols, e.g., (:Main, :ABC, :DEF)
    # TBD: use Base.moduleroot(__module__) to get the first in that sequence, if needed
    # TBD: parentmodule(m) gets the enclosing module (but for root modules returns self)
    # TBD: might need to replace the single symbol used for module name in ComponentId with Module path.

    # @info "imports: $imports"
    # @info "  $(length(imports)) elements"
    # global IMP = imports

    result = :(
        let conns = $conns,
            imports = $imports
            cc_id = Mimi.ComponentId($__module__, $(QuoteNode(cc_name)))
        
            global $cc_name = Mimi.CompositeComponentDef(cc_id, $(QuoteNode(cc_name)), $comps, $__module__)

            for ((dst_path, dst_name), (src_path, src_name)) in conns
                Mimi.connect_param!($cc_name, dst_path, dst_name, src_path, src_name)
            end
            
            for (local_name, item) in imports
                refs = []

                for (src_path, src_name) in item
                    dr = Mimi.DatumReference(src_name, $cc_name, src_path)
                    var_par_ref = (Mimi.is_parameter(dr) ? Mimi.ParameterDefReference(dr) : Mimi.VariableDefReference(dr))
                    push!(refs, var_par_ref)
                end
                
                # we allow linking parameters, but not variables.
                count = length(refs)
                if count == 1 && refs[1] isa Mimi.VariableDefReference
                    $cc_name[local_name] = refs[1]      # store single VariableDefReference; multiples not supported
                else
                    if count > 1
                        vars = filter(obj -> obj isa Mimi.VariableDefReference, refs)
                        if length(vars) > 0
                            error("Variables ($vars) must be aliased only individually.")
                        end
                    end

                    $cc_name[local_name] = Vector{Mimi.ParameterDefReference}(refs)  # tweak array type
                end
            end

            Mimi.import_params($cc_name)

            $cc_name
        end
    )

    # @info "defcomposite:\n$result"
    return esc(result)
end

nothing
