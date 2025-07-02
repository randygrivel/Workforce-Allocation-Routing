include("C:\\TSA-Allocation\\julia\\DataProcessing.jl")
include("C:\\TSA-Allocation\\julia\\Networkconstruction.jl")
include("C:\\TSA-Allocation\\julia\\ModelConstruction.jl")
using CPLEX
using MathOptInterface
const MOI = MathOptInterface

Distributions.Random.seed!(4444)

function read_data_and_solve_model(
    file;
    hours = 2,
    gap = 0.0001,
    allow_ot = true,
    allow_certifications = true,
    fix_break_selections = false,
    movement_indicator = '3', # movement_indicator '1' is no movement, '2' after breaks, '3' all the time
    solution_output = "out.csv",
    ignore_extreme_changes = false,
    )

    @info("Reading input data")
    areas, baggage_df, shifts_df, breaks_df, overtime_df, parameters, travel, arrivals, cert_list = read_input_data(file; test_cert = true)

    # ~~~
    # Solver attributes
    # ~~~
    @info("Setting Solver Attributes")
    time_limit = 60*60*hours
    model = Model(CPLEX.Optimizer)
    set_time_limit_sec(model, time_limit)
    MOI.set(model, MOI.RelativeGapTolerance(), gap)

    if !allow_certifications
        @info("Removing certifications from shifts, breaks, and overtime dataframes")
        shifts_df = remove_shifts_certifications(shifts_df)
        breaks_df = remove_breaks_certifications(breaks_df; fixed_breaks = fix_break_selections)
        overtime_df = remove_overtime_certifications(overtime_df)
    end
    
    if movement_indicator == '1'
        @info("Creating no movement break network")
        break_network_dict = construct_network_breaks_area_no_movement(breaks_df, areas, travel)
        @info("Creating no movement overtime network")
        overtime_network_dict = construct_network_overtime_area_no_movement(overtime_df, areas, travel)
    elseif movement_indicator == '2'
        @info("Creating movement after breaks break network")
        break_network_dict = construct_network_breaks_area_movement_after_breaks(breaks_df, areas, travel)
        @info("Creating no movement overtime network")
        overtime_network_dict = construct_network_overtime_area_no_movement(overtime_df, areas, travel)
    elseif movement_indicator == '3'
        @info("Creating movement all the time break network")
        break_network_dict = construct_network_breaks_area(breaks_df, areas, travel)
        @info("Creating movement all the time overtime network")
        overtime_network_dict = construct_network_overtime_area(overtime_df, areas, travel)
    end
    
    @info("Determining model type from design attributes")
    if allow_ot && allow_certifications
        model_type = 1
    elseif allow_ot && !allow_certifications
        model_type = 2
    elseif !allow_ot && allow_certifications
        model_type = 3
    else
        model_type = 4
    end

    @info("Model type: ", model_type)

    @info("Constructing model")
    construct_model(
        model,
        areas, baggage_df, shifts_df, breaks_df, overtime_df, parameters, arrivals,
        break_network_dict,
        overtime_network_dict,
        model_type,
        cert_list;
        ignore_extreme_changes = ignore_extreme_changes
    )

    if fix_break_selections
        @info("Fixing the break selections randomly")
        fix_breaks!(model, breaks_df)
    end

    @info("optimizing model")
    optimize!(model)

    if termination_status == MOI.INFEASIBLE || termination_status == MOI.DUAL_INFEASIBLE
        @warn("Infeasible or unbounded model.")
    elseif !feasible_solution_found && termination_status == MOI.TIME_LIMIT
        @warn("No feasible solution found within time limit.")
    else
        if feasible_solution_found
            @info("writing solution")
            solution_df = DataFrame(variable_name = Any[], index_1 = Any[], index_2 = Any[],
                                        index_3 = Any[], index_4 = Any[], index_5 = Any[],
                                        index_6 = Any[], value = Any[])

            for v in all_variables(model)
                name_ = substring_to_character(string(v), "[")
                if value(v) > 0.0001 || value(v) < -0.0001
                    # delimit everything
                    index_array = split(string(v), r"[\[\],]")
                    
                    # get rid of empty entries
                    index_array = filter(x -> x != "", index_array)
                    
                    # take everything after the variable name
                    index_array = index_array[2:end]
                    # make sure there are six entries
                    for entry in (length(index_array)+1):6
                        push!(index_array, "")
                    end
                    # append to solution dataframe
                    push!(solution_df, vcat(name_, index_array, value(v)))
                end
            end

            if !isdir("outputs")
                mkdir("outputs")
            end

            CSV.write("$(solution_output)", solution_df)
        else
            solution_gap = NaN
            obj = NaN
            overtime_cost = NaN
            queue_cost = NaN
        end
    end

    return shifts_df, breaks_df, overtime_df
end

read_data_and_solve_model(
    "test_input.xlsx";
    solution_output = "test_output.csv"
)
