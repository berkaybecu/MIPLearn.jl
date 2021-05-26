#  MIPLearn: Extensible Framework for Learning-Enhanced Mixed-Integer Optimization
#  Copyright (C) 2020-2021, UChicago Argonne, LLC. All rights reserved.
#  Released under the modified BSD license. See COPYING.md for more details.

using Cbc
using Gurobi
using JuMP
using MIPLearn
using PyCall
using Test

miplearn_tests = pyimport("miplearn.solvers.tests")
traceback = pyimport("traceback")

function _test_solver(optimizer_factory)
    MIPLearn.@python_call miplearn_tests.run_internal_solver_tests(
        JuMPSolver(optimizer_factory),
    )
end

@testset "JuMPSolver" begin
    @testset "Cbc" begin
        _test_solver(Cbc.Optimizer)
    end
    if "GUROBI_HOME" in keys(ENV)
        @testset "Gurobi" begin
            _test_solver(Gurobi.Optimizer)
        end
    end
end
