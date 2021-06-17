#  MIPLearn: Extensible Framework for Learning-Enhanced Mixed-Integer Optimization
#  Copyright (C) 2020-2021, UChicago Argonne, LLC. All rights reserved.
#  Released under the modified BSD license. See COPYING.md for more details.

using JuMP
using JLD2

function __init_PyJuMPInstance__()
    @pydef mutable struct Class <: miplearn.Instance
        function __init__(self, model)
            init_miplearn_ext(model)
            self.model = model
            self.samples = []
        end

        function to_model(self)
            return self.model
        end

        function get_instance_features(self)
            return self.model.ext[:miplearn][:instance_features]
        end

        function get_variable_features(self, var_name)
            model = self.model
            return get(model.ext[:miplearn][:variable_features], var_name, nothing)
        end

        function get_variable_category(self, var_name)
            model = self.model
            return get(model.ext[:miplearn][:variable_categories], var_name, nothing)
        end

        function get_constraint_features(self, cname)
            model = self.model
            return get(model.ext[:miplearn][:constraint_features], cname, nothing)
        end

        function get_constraint_category(self, cname)
            model = self.model
            return get(model.ext[:miplearn][:constraint_categories], cname, nothing)
        end
    end
    copy!(PyJuMPInstance, Class)
end


struct JuMPInstance <: Instance
    py::PyCall.PyObject
    model::Model
end


function JuMPInstance(model)
    model isa Model || error("model should be a JuMP.Model. Found $(typeof(model)) instead.")
    return JuMPInstance(
        PyJuMPInstance(model),
        model,
    )
end


function save(filename::AbstractString, instance::JuMPInstance)::Nothing
    @info "Writing: $filename"
    time = @elapsed begin
        # Convert JuMP model to MPS
        mps_filename = "$(tempname()).mps.gz"
        write_to_file(instance.model, mps_filename)
        mps = read(mps_filename)

        # Pickle instance.py.samples. Ideally, we would use dumps and loads, but this
        # causes some issues with PyCall, probably due to automatic type conversions.
        py_samples_filename = tempname()
        miplearn.write_pickle_gz(instance.py.samples, py_samples_filename, quiet=true)
        py_samples = read(py_samples_filename)

        # Generate JLD2 file
        jldsave(
            filename;
            miplearn_version="0.2",
            mps=mps,
            ext=instance.model.ext[:miplearn],
            py_samples=py_samples,
        )
    end
    @info @sprintf("File written in %.2f seconds", time)
    return
end

function _check_miplearn_version(file)
    v = file["miplearn_version"]
    v == "0.2" || error(
        "The file you are trying to load has been generated by " *
        "MIPLearn $(v) and you are currently running MIPLearn 0.2. " *
        "Reading files generated by different versions of MIPLearn is " *
        "not currently supported."
    )
end


function load_instance(filename::AbstractString)::JuMPInstance
    @info "Reading: $filename"
    instance = nothing
    time = @elapsed begin
        jldopen(filename, "r") do file
            _check_miplearn_version(file)

            # Convert MPS to JuMP
            mps_filename = "$(tempname()).mps.gz"
            write(mps_filename, file["mps"])
            model = read_from_file(mps_filename)
            model.ext[:miplearn] = file["ext"]

            # Unpickle instance.py.samples
            py_samples_filename = tempname()
            write(py_samples_filename, file["py_samples"])
            py_samples = miplearn.read_pickle_gz(py_samples_filename, quiet=true)

            instance = JuMPInstance(model)
            instance.py.samples = py_samples
        end
    end
    @info @sprintf("File read in %.2f seconds", time)
    return instance
end


export JuMPInstance, save, load_instance
