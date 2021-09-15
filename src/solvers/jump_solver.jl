#  MIPLearn: Extensible Framework for Learning-Enhanced Mixed-Integer Optimization
#  Copyright (C) 2020-2021, UChicago Argonne, LLC. All rights reserved.
#  Released under the modified BSD license. See COPYING.md for more details.

using Cbc
using Clp
using JuMP
using MathOptInterface
using TimerOutputs
using SparseArrays
const MOI = MathOptInterface

import JuMP: value

Base.@kwdef mutable struct JuMPSolverData
    optimizer_factory::Any
    basis_status::Dict{ConstraintRef,MOI.BasisStatusCode} = Dict()
    bin_vars::Vector{JuMP.VariableRef} = []
    cb_data::Any = nothing
    cname_to_constr::Dict{String,JuMP.ConstraintRef} = Dict()
    dual_values::Dict{JuMP.ConstraintRef,Float64} = Dict()
    instance::Union{Nothing,PyObject} = nothing
    model::Union{Nothing,JuMP.Model} = nothing
    reduced_costs::Vector{Float64} = []
    sensitivity_report::Any = nothing
    solution::Dict{JuMP.VariableRef,Float64} = Dict()
    var_lb_constr::Dict{MOI.VariableIndex,ConstraintRef} = Dict()
    var_ub_constr::Dict{MOI.VariableIndex,ConstraintRef} = Dict()
    varname_to_var::Dict{String,VariableRef} = Dict()
    x::Vector{Float64} = Float64[]
end


"""
    _optimize_and_capture_output!(model; tee=tee)

Optimizes a given JuMP model while capturing the solver log, then returns that log.
If tee=true, prints the solver log to the standard output as the optimization takes place.
"""
function _optimize_and_capture_output!(model; tee::Bool = false)
    logname = tempname()
    logfile = open(logname, "w")
    redirect_stdout(logfile) do
        JuMP.optimize!(model)
        Base.Libc.flush_cstdio()
    end
    close(logfile)
    log = String(read(logname))
    rm(logname)
    if tee
        println(log)
        flush(stdout)
        Base.Libc.flush_cstdio()
    end
    return log
end


function _update_solution!(data::JuMPSolverData)
    vars = JuMP.all_variables(data.model)
    data.solution = Dict(var => JuMP.value(var) for var in vars)
    data.x = JuMP.value.(vars)

    if has_duals(data.model)
        data.reduced_costs = []
        data.basis_status = Dict()

        for var in vars
            rc = 0.0
            if has_upper_bound(var)
                rc += shadow_price(UpperBoundRef(var))
            end
            if has_lower_bound(var)
                # FIXME: Remove negative sign
                rc -= shadow_price(LowerBoundRef(var))
            end
            if is_fixed(var)
                rc += shadow_price(FixRef(var))
            end
            push!(data.reduced_costs, rc)
        end

        try
            data.sensitivity_report = lp_sensitivity_report(data.model)
        catch
            @warn "Sensitivity analysis is unavailable; ignoring" maxlog = 1
        end

        basis_status_supported = true
        data.dual_values = Dict()
        for (ftype, stype) in JuMP.list_of_constraint_types(data.model)
            for constr in JuMP.all_constraints(data.model, ftype, stype)
                # Dual values (FIXME: Remove negative sign)
                data.dual_values[constr] = -JuMP.dual(constr)

                # Basis status
                if basis_status_supported
                    try
                        data.basis_status[constr] =
                            MOI.get(data.model, MOI.ConstraintBasisStatus(), constr)
                    catch
                        @warn "Basis status is unavailable; ignoring" maxlog = 1
                        basis_status_supported = false
                        data.basis_status = Dict()
                    end
                end

                # Build map between variables and bound constraints
                if ftype == VariableRef
                    var = MOI.get(data.model, MOI.ConstraintFunction(), constr).variable
                    if stype == MOI.GreaterThan{Float64}
                        data.var_lb_constr[var] = constr
                    elseif stype == MOI.LessThan{Float64}
                        data.var_ub_constr[var] = constr
                    else
                        error("Unsupported constraint: $(ftype)-in-$(stype)")
                    end
                end
            end
        end

    else
        data.reduced_costs = []
        data.dual_values = Dict()
        data.sensitivity_report = nothing
        data.basis_status = Dict()
        data.var_lb_constr = Dict()
        data.var_ub_constr = Dict()
    end
end


function add_constraints(
    data::JuMPSolverData;
    lhs::SparseMatrixCSC,
    rhs::Vector{Float64},
    senses::Vector{String},
    names::Vector{String},
)::Nothing
    lhs_exprs = lhs * JuMP.all_variables(data.model)
    for (i, lhs_expr) in enumerate(lhs_exprs)
        if senses[i] == ">"
            constr = @constraint(data.model, lhs_expr >= rhs[i])
        elseif senses[i] == "<"
            constr = @constraint(data.model, lhs_expr <= rhs[i])
        elseif senses[i] == "="
            constr = @constraint(data.model, lhs_expr == rhs[i])
        else
            error("unknown sense: $sense")
        end
        set_name(constr, names[i])
        data.cname_to_constr[names[i]] = constr
    end
    data.solution = Dict()
    data.x = Float64[]
    return
end


function are_constraints_satisfied(
    data::JuMPSolverData;
    lhs::SparseMatrixCSC,
    rhs::Vector{Float64},
    senses::Vector{String},
    tol::Float64 = 1e-5,
)::Vector{Bool}
    result = Bool[]
    lhs_value = lhs * data.x
    for (i, sense) in enumerate(senses)
        sense = senses[i]
        if sense == "<"
            push!(result, lhs_value[i] <= rhs[i] + tol)
        elseif sense == ">"
            push!(result, lhs_value[i] >= rhs[i] - tol)
        elseif sense == "<"
            push!(result, abs(rhs[i] - lhs_value[i]) <= tol)
        else
            error("unknown sense: $sense")
        end
    end
    return result
end


function build_test_instance_knapsack()
    weights = [23.0, 26.0, 20.0, 18.0]
    prices = [505.0, 352.0, 458.0, 220.0]
    capacity = 67.0

    model = Model()
    n = length(weights)
    @variable(model, x[0:n-1], Bin)
    @variable(model, z, lower_bound = 0.0, upper_bound = capacity)
    @objective(model, Max, sum(x[i-1] * prices[i] for i = 1:n))
    @constraint(model, eq_capacity, sum(x[i-1] * weights[i] for i = 1:n) - z == 0)

    return JuMPInstance(model).py
end


function build_test_instance_infeasible()
    model = Model()
    @variable(model, x, Bin)
    @objective(model, Max, x)
    @constraint(model, x >= 2)
    return JuMPInstance(model).py
end


function remove_constraints(data::JuMPSolverData, names::Vector{String})::Nothing
    for name in names
        constr = data.cname_to_constr[name]
        delete(data.model, constr)
        delete!(data.cname_to_constr, name)
    end
    return
end


function solve(
    data::JuMPSolverData;
    tee::Bool = false,
    iteration_cb = nothing,
    lazy_cb = nothing,
)
    model = data.model
    wallclock_time = 0
    log = ""

    if lazy_cb !== nothing
        function lazy_cb_wrapper(cb_data)
            data.cb_data = cb_data
            lazy_cb(nothing, nothing)
            data.cb_data = nothing
        end
        MOI.set(model, MOI.LazyConstraintCallback(), lazy_cb_wrapper)
    end

    while true
        wallclock_time += @elapsed begin
            log *= _optimize_and_capture_output!(model, tee = tee)
        end
        if is_infeasible(data)
            break
        end
        if iteration_cb !== nothing
            iteration_cb() || break
        else
            break
        end
    end

    if is_infeasible(data)
        data.solution = Dict()
        data.x = Float64[]
        primal_bound = nothing
        dual_bound = nothing
    else
        _update_solution!(data)
        primal_bound = JuMP.objective_value(model)
        dual_bound = JuMP.objective_bound(model)
    end
    if JuMP.objective_sense(model) == MOI.MIN_SENSE
        sense = "min"
        lower_bound = dual_bound
        upper_bound = primal_bound
    else
        sense = "max"
        lower_bound = primal_bound
        upper_bound = dual_bound
    end
    return miplearn.solvers.internal.MIPSolveStats(
        mip_lower_bound = lower_bound,
        mip_upper_bound = upper_bound,
        mip_sense = sense,
        mip_wallclock_time = wallclock_time,
        mip_nodes = 1,
        mip_log = log,
        mip_warm_start_value = nothing,
    )
end


function solve_lp(data::JuMPSolverData; tee::Bool = false)
    model, bin_vars = data.model, data.bin_vars
    for var in bin_vars
        ~is_fixed(var) || continue
        unset_binary(var)
        set_upper_bound(var, 1.0)
        set_lower_bound(var, 0.0)
    end
    # If the optimizer is Cbc, we need to replace it by Clp,
    # otherwise dual values are not available.
    # https://github.com/jump-dev/Cbc.jl/issues/50
    is_cbc = (data.optimizer_factory == Cbc.Optimizer)
    if is_cbc
        set_optimizer(model, Clp.Optimizer)
    end
    wallclock_time = @elapsed begin
        log = _optimize_and_capture_output!(model, tee = tee)
    end
    if is_infeasible(data)
        data.solution = Dict()
        obj_value = nothing
    else
        _update_solution!(data)
        obj_value = objective_value(model)
    end
    if is_cbc
        set_optimizer(model, data.optimizer_factory)
    end
    for var in bin_vars
        ~is_fixed(var) || continue
        set_binary(var)
    end
    return miplearn.solvers.internal.LPSolveStats(
        lp_value = obj_value,
        lp_log = log,
        lp_wallclock_time = wallclock_time,
    )
end


function set_instance!(
    data::JuMPSolverData,
    instance;
    model::Union{Nothing,JuMP.Model},
)::Nothing
    data.instance = instance
    if model === nothing
        model = instance.to_model()
    end
    data.model = model
    data.bin_vars = [var for var in JuMP.all_variables(model) if JuMP.is_binary(var)]
    data.varname_to_var = Dict(JuMP.name(var) => var for var in JuMP.all_variables(model))
    JuMP.set_optimizer(model, data.optimizer_factory)
    data.cname_to_constr = Dict()
    for (ftype, stype) in JuMP.list_of_constraint_types(model)
        for constr in JuMP.all_constraints(model, ftype, stype)
            name = JuMP.name(constr)
            length(name) > 0 || continue
            data.cname_to_constr[name] = constr
        end
    end
    return
end


function fix!(data::JuMPSolverData, solution)
    for (varname, value) in solution
        value !== nothing || continue
        var = data.varname_to_var[varname]
        JuMP.fix(var, value, force = true)
    end
end


function set_warm_start!(data::JuMPSolverData, solution)
    for (varname, value) in solution
        value !== nothing || continue
        var = data.varname_to_var[varname]
        JuMP.set_start_value(var, value)
    end
end


function is_infeasible(data::JuMPSolverData)
    return JuMP.termination_status(data.model) in
           [MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED]
end


function get_variables(data::JuMPSolverData; with_static::Bool, with_sa::Bool)
    vars = JuMP.all_variables(data.model)
    lb, ub, types = nothing, nothing, nothing
    sa_obj_down, sa_obj_up = nothing, nothing
    sa_lb_down, sa_lb_up = nothing, nothing
    sa_ub_down, sa_ub_up = nothing, nothing
    basis_status = nothing
    values, rc = nothing, nothing

    # Variable names
    names = JuMP.name.(vars)

    # Primal values
    if !isempty(data.solution)
        values = [data.solution[v] for v in vars]
    end

    # Objective function coefficients
    obj = objective_function(data.model)
    obj_coeffs = [v ∈ keys(obj.terms) ? obj.terms[v] : 0.0 for v in vars]

    if with_static
        # Lower bounds
        lb = [
            JuMP.is_binary(v) ? 0.0 : JuMP.has_lower_bound(v) ? JuMP.lower_bound(v) : -Inf for v in vars
        ]

        # Upper bounds
        ub = [
            JuMP.is_binary(v) ? 1.0 : JuMP.has_upper_bound(v) ? JuMP.upper_bound(v) : Inf for v in vars
        ]

        # Variable types
        types = [JuMP.is_binary(v) ? "B" : JuMP.is_integer(v) ? "I" : "C" for v in vars]
    end

    # Sensitivity analysis
    if data.sensitivity_report !== nothing
        sa_obj_down, sa_obj_up = Float64[], Float64[]
        sa_lb_down, sa_lb_up = Float64[], Float64[]
        sa_ub_down, sa_ub_up = Float64[], Float64[]

        for (i, v) in enumerate(vars)
            # Objective function
            (delta_down, delta_up) = data.sensitivity_report[v]
            push!(sa_obj_down, delta_down + obj_coeffs[i])
            push!(sa_obj_up, delta_up + obj_coeffs[i])

            # Lower bound
            if v.index in keys(data.var_lb_constr)
                constr = data.var_lb_constr[v.index]
                (delta_down, delta_up) = data.sensitivity_report[constr]
                push!(sa_lb_down, lower_bound(v) + delta_down)
                push!(sa_lb_up, lower_bound(v) + delta_up)
            else
                push!(sa_lb_down, -Inf)
                push!(sa_lb_up, -Inf)
            end

            # Upper bound
            if v.index in keys(data.var_ub_constr)
                constr = data.var_ub_constr[v.index]
                (delta_down, delta_up) = data.sensitivity_report[constr]
                push!(sa_ub_down, upper_bound(v) + delta_down)
                push!(sa_ub_up, upper_bound(v) + delta_up)
            else
                push!(sa_ub_down, Inf)
                push!(sa_ub_up, Inf)
            end
        end
    end

    # Basis status
    if !isempty(data.basis_status)
        basis_status = []
        for v in vars
            basis_status_v = "B"
            if v.index in keys(data.var_lb_constr)
                constr = data.var_lb_constr[v.index]
                if data.basis_status[constr] == MOI.NONBASIC
                    basis_status_v = "L"
                end
            end
            if v.index in keys(data.var_ub_constr)
                constr = data.var_ub_constr[v.index]
                if data.basis_status[constr] == MOI.NONBASIC
                    basis_status_v = "U"
                end
            end
            push!(basis_status, basis_status_v)
        end
    end

    rc = isempty(data.reduced_costs) ? nothing : data.reduced_costs

    vf = miplearn.solvers.internal.Variables(
        basis_status = to_str_array(basis_status),
        lower_bounds = lb,
        names = to_str_array(names),
        obj_coeffs = with_static ? obj_coeffs : nothing,
        reduced_costs = rc,
        sa_lb_down = with_sa ? sa_lb_down : nothing,
        sa_lb_up = with_sa ? sa_lb_up : nothing,
        sa_obj_down = with_sa ? sa_obj_down : nothing,
        sa_obj_up = with_sa ? sa_obj_up : nothing,
        sa_ub_down = with_sa ? sa_ub_down : nothing,
        sa_ub_up = with_sa ? sa_ub_up : nothing,
        types = to_str_array(types),
        upper_bounds = ub,
        values = values,
    )
    return vf
end


function get_constraints(
    data::JuMPSolverData;
    with_static::Bool,
    with_sa::Bool,
    with_lhs::Bool,
)
    names = String[]
    senses, rhs = String[], Float64[]
    lhs_rows, lhs_cols, lhs_values = Int[], Int[], Float64[]
    dual_values, slacks = nothing, nothing
    basis_status = nothing
    sa_rhs_up, sa_rhs_down = nothing, nothing

    if !isempty(data.dual_values)
        dual_values = Float64[]
    end
    if !isempty(data.basis_status)
        basis_status = []
    end
    if data.sensitivity_report !== nothing
        sa_rhs_up, sa_rhs_down = Float64[], Float64[]
    end

    constr_index = 1
    for (ftype, stype) in JuMP.list_of_constraint_types(data.model)
        for constr in JuMP.all_constraints(data.model, ftype, stype)
            cset = MOI.get(constr.model.moi_backend, MOI.ConstraintSet(), constr.index)
            cf = MOI.get(constr.model.moi_backend, MOI.ConstraintFunction(), constr.index)

            # Names
            name = JuMP.name(constr)
            length(name) > 0 || continue
            push!(names, name)

            # LHS, RHS and sense
            if ftype == VariableRef
                # nop
            elseif ftype == AffExpr
                if stype == MOI.EqualTo{Float64}
                    rhs_c = cset.value
                    push!(senses, "=")
                elseif stype == MOI.LessThan{Float64}
                    rhs_c = cset.upper
                    push!(senses, "<")
                elseif stype == MOI.GreaterThan{Float64}
                    rhs_c = cset.lower
                    push!(senses, ">")
                else
                    error("Unsupported set: $stype")
                end
                push!(rhs, rhs_c)
                for term in cf.terms
                    push!(lhs_cols, term.variable_index.value)
                    push!(lhs_rows, constr_index)
                    push!(lhs_values, term.coefficient)
                end
                constr_index += 1
            else
                error("Unsupported constraint type: ($ftype, $stype)")
            end

            # Dual values
            if !isempty(data.dual_values)
                push!(dual_values, data.dual_values[constr])
            end

            # Basis status
            if !isempty(data.basis_status)
                b = data.basis_status[constr]
                if b == MOI.NONBASIC
                    push!(basis_status, "N")
                elseif b == MOI.BASIC
                    push!(basis_status, "B")
                else
                    error("Unknown basis status: $b")
                end
            end

            # Sensitivity analysis
            if data.sensitivity_report !== nothing
                (delta_down, delta_up) = data.sensitivity_report[constr]
                push!(sa_rhs_down, rhs_c + delta_down)
                push!(sa_rhs_up, rhs_c + delta_up)
            end
        end
    end

    lhs =
        sparse(lhs_rows, lhs_cols, lhs_values, length(rhs), JuMP.num_variables(data.model))
    if !isempty(data.x)
        lhs_value = lhs * data.x
        slacks = abs.(lhs_value - rhs)
    end

    return miplearn.solvers.internal.Constraints(
        basis_status = to_str_array(basis_status),
        dual_values = dual_values,
        lhs = (with_static && with_lhs) ? sparse(lhs_rows, lhs_cols, lhs_values) : nothing,
        names = to_str_array(names),
        rhs = with_static ? rhs : nothing,
        sa_rhs_down = with_sa ? sa_rhs_down : nothing,
        sa_rhs_up = with_sa ? sa_rhs_up : nothing,
        senses = with_static ? to_str_array(senses) : nothing,
        slacks = slacks,
    )
end


function __init_JuMPSolver__()
    @pydef mutable struct Class <: miplearn.solvers.internal.InternalSolver
        function __init__(self, optimizer_factory)
            self.data = JuMPSolverData(optimizer_factory = optimizer_factory)
        end

        function add_constraints(self, cf)
            add_constraints(
                self.data,
                lhs = convert(SparseMatrixCSC, cf.lhs),
                rhs = cf.rhs,
                senses = from_str_array(cf.senses),
                names = from_str_array(cf.names),
            )
        end

        function are_constraints_satisfied(self, cf; tol = 1e-5)
            return are_constraints_satisfied(
                self.data,
                lhs = convert(SparseMatrixCSC, cf.lhs),
                rhs = cf.rhs,
                senses = from_str_array(cf.senses),
                tol = tol,
            )
        end

        build_test_instance_infeasible(self) = build_test_instance_infeasible()

        build_test_instance_knapsack(self) = build_test_instance_knapsack()

        clone(self) = JuMPSolver(self.data.optimizer_factory)

        fix(self, solution) = fix!(self.data, solution)

        get_solution(self) = isempty(self.data.solution) ? nothing : self.data.solution

        get_constraints(self; with_static = true, with_sa = true, with_lhs = true) =
            get_constraints(
                self.data,
                with_static = with_static,
                with_sa = with_sa,
                with_lhs = with_lhs,
            )

        function get_constraint_attrs(self)
            attrs = [
                "categories",
                "dual_values",
                "lazy",
                "lhs",
                "names",
                "rhs",
                "senses",
                "user_features",
                "slacks",
            ]
            if repr(self.data.optimizer_factory) in ["Gurobi.Optimizer"]
                append!(attrs, ["basis_status", "sa_rhs_down", "sa_rhs_up"])
            end
            return attrs
        end

        get_variables(self; with_static = true, with_sa = true) =
            get_variables(self.data; with_static = with_static, with_sa = with_sa)

        function get_variable_attrs(self)
            attrs = [
                "names",
                "categories",
                "lower_bounds",
                "obj_coeffs",
                "reduced_costs",
                "types",
                "upper_bounds",
                "user_features",
                "values",
            ]
            if repr(self.data.optimizer_factory) in ["Gurobi.Optimizer"]
                append!(
                    attrs,
                    [
                        "basis_status",
                        "sa_obj_down",
                        "sa_obj_up",
                        "sa_lb_down",
                        "sa_lb_up",
                        "sa_ub_down",
                        "sa_ub_up",
                    ],
                )
            end
            return attrs
        end

        is_infeasible(self) = is_infeasible(self.data)

        remove_constraints(self, names) = remove_constraints(self.data, [n for n in names])

        set_instance(self, instance, model = nothing) =
            set_instance!(self.data, instance, model = model)

        set_warm_start(self, solution) = set_warm_start!(self.data, solution)

        solve(
            self;
            tee = false,
            iteration_cb = nothing,
            lazy_cb = nothing,
            user_cut_cb = nothing,
        ) = solve(self.data, tee = tee, iteration_cb = iteration_cb, lazy_cb = lazy_cb)

        solve_lp(self; tee = false) = solve_lp(self.data, tee = tee)
    end
    copy!(JuMPSolver, Class)
end

function value(solver::JuMPSolverData, var::VariableRef)
    if solver.cb_data !== nothing
        return JuMP.callback_value(solver.cb_data, var)
    else
        return JuMP.value(var)
    end
end

function submit(solver::JuMPSolverData, con::AbstractConstraint, name::String = "")
    if solver.cb_data !== nothing
        MOI.submit(solver.model, MOI.LazyConstraint(solver.cb_data), con)
    else
        JuMP.add_constraint(solver.model, con, name)
    end
end

export JuMPSolver, submit
