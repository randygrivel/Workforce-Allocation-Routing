using XLSX, DataFrames, CSV, Distributions

######
# OUTPUTS AND FORMATTING FROM READ INPUT
######
# areas_dict is formatted:
#   area =>
#       dictionary{ "Nodes" => Vector with all nodes (TDCs/SLs)
#                   "Stations" => Vector of vectors with stations layout,
#                                   areas_dict[area]["Stations"][i] returns the vector of feasible stations of node i  
#                   "Period Opened" => int period Opened
#                   "Period Closed" => int period closed
#                   "Buffer Capacities" => vector of the buffer capacity for each node
#                   "Rates" => vector of vectors of the processing rates of stations
#                                   areas_dict[area]["Rates"][i] returns the vector of rates for feasible stations of node i
#                   "Resources" => vector of vectors for the resources required to work a given station
#                                   areas_dict[area]["Resources"][i] is the vector of resources for the stations of node i
#                   "__CERTIFICATION__" => for any given certification a vector of vectors is created to store the required resources for a given type of certification
#                   }
# baggage_df is formatted with two headers "Time Period" and "Needs"
# shifts_df is formatted with four standard headers "Shift ID", "Hired", ~ these two might not be required double check this "Start", "End"~
#   the remaining headers for shifts_df are "Cert _CERTIFICATION_" for each certification
# breaks_df is formatted with headers "Shift ID", "Break ID", "Start", "End", "Breaks"
#   where "Breaks" is either a vector of all breaks, an Integer of a singular break, or missing for no breaks
# overtime_df is formatted with headers "Shift ID", "Overtime ID", "Start", "End", and "Cost"
# parameters is a dictionary with "time_periods" => int number of time periods, "scenarios"=> int number of scenarios,
#   "fraction_shift_OT" => points to the fraction of workers hired to a shift that can work OT, and others
# travel is a dictionary that maps [[i,j],[k,l]] => int number of periods to travel from area i node j to area k node l
# arrivals is a vector of vectors, arrivals[time_period][scenario][area] gives the arrivals for a time_period, scenario and area combo
# cert_list is a vector that returns all the certifications that are included in the model

#TODO: refactor "Stations" to configurations to be more consistent with terminology used for TSA
function read_input_data(filename::AbstractString; test_cert = false)
    areas_df = DataFrame(XLSX.readtable(filename, "Service Areas"))
    areas_dict = Dict()
    for area ∈ eachrow(areas_df)
        areas_dict[area["Service Area"]] = create_area_dictionary(area)
    end
    baggage_df = DataFrame(XLSX.readtable(filename, "Baggage"))

    shifts_df = DataFrame(XLSX.readtable(filename, "Shifts"))

    if !test_cert
        cert_list_df = select(shifts_df, r"Cert" )
        rename!(cert_list_df, names(cert_list_df) .|> x -> replace(x, "Cert " => ""))
        cert_list = names(cert_list_df)
        
        cert_requirements_df = DataFrame(XLSX.readtable(filename, "Certification Requirements"))

        for area in keys(areas_dict)
            for node in areas_dict[area]["Nodes"]
                for certification in cert_list
                    if !haskey(areas_dict[area], certification)
                        areas_dict[area][certification] = []
                    end
                    station_cert_req = filter(row -> row.Area == area && row.Node == node, cert_requirements_df)[1, certification]
                    
                    #TODO: FIX FOR THE CASE WHEN THERE IS ONLY ONE TDC / ONE SL
                    station_cert_req = parse.(Int, split(station_cert_req, ','))

                    append!(areas_dict[area][certification], [vcat(0, station_cert_req)])
                end
            end
        end
    else
        cert_list = ["F", "M", "SSCP", "Bag"]
        cert_requirements_df = DataFrame(XLSX.readtable(filename, "Certification Requirements"))

        for area in keys(areas_dict)
            for node in areas_dict[area]["Nodes"]
                for certification in cert_list
                    if !haskey(areas_dict[area], certification)
                        areas_dict[area][certification] = []
                    end
                    station_cert_req = filter(row -> row.Area == area && row.Node == node, cert_requirements_df)[1, certification]
                    #TODO: FIX FOR THE CASE WHEN THERE IS ONLY ONE TDC / ONE SL
                    station_cert_req = parse.(Int, split(station_cert_req, ','))
                    
                    append!(areas_dict[area][certification], [vcat(0, station_cert_req)])
                end
            end
        end
    end

    breaks_df = DataFrame(XLSX.readtable(filename, "Breaks"))
    for row ∈ eachrow(breaks_df)
        if occursin(",", string(row.Breaks))
            row.Breaks = parse.(Int, split(row.Breaks, ","))
        end
    end

    overtime_df = DataFrame(XLSX.readtable(filename, "Overtime"))
    
    parameters_df = DataFrame(XLSX.readtable(filename, "Parameters"))
    
    parameters = Dict()
    parameters["time_periods"] = parameters_df[parameters_df."Name" .== "time_periods", :"Value"][1]
    parameters["scenarios"] = parameters_df[parameters_df."Name" .== "num_scenarios", :"Value"][1]
    parameters["M"] = parameters_df[parameters_df."Name" .== "M", :"Value"][1]
    if typeof(parameters_df[parameters_df."Name".=="scenario_weights", :"Value"][1]) == String
        parameters["scenario_weights"] = parse.(Float64, split(parameters_df[parameters_df."Name".=="scenario_weights", :"Value"][1],','))
    else
        parameters["scenario_weights"] = 1
    end
    parameters["cost_regularization"] = parse.(Float64, split(parameters_df[parameters_df."Name".=="cost_regularization", :"Value"][1],','))
    parameters["fraction_shift_OT"] = parameters_df[parameters_df."Name" .== "fraction_shift_OT", :"Value"][1]

    beta_df = DataFrame(XLSX.readtable(filename, "Machine Learning"))
    for i ∈ 0:8
        parameters["β_$(i)"] = round(beta_df[beta_df."Beta".==i, "Value"][1],digits = 4)
    end

    parameters["config_cost"] = parameters_df[parameters_df."Name" .== "per_period_per_config_cost", :"Value"][1]
    parameters["ramp_penalty"] = parameters_df[parameters_df."Name" .== "ramp_penalty", :"Value"][1]
    
    traveling_df = DataFrame(XLSX.readtable(filename, "Walking"))
    travel = Dict()
    for arc ∈ eachrow(traveling_df)
        origin_pair = [arc["Origin Area"], arc["Origin Node"]]
        destination_pair = [arc["Destination Area"], arc["Destination Node"]]
        travel[[origin_pair, destination_pair]] = arc["Periods"]
    end

    arrivals_df = DataFrame(XLSX.readtable(filename, "Arrivals"))
    # arrivals is formatted [time period][scenario][area]
    arrivals = []
    for period ∈ eachrow(arrivals_df)
        arrivals_tuple = [period[col] for col in names(arrivals_df) if col != "Time Period"]
        s = parameters["scenarios"]
        arrivals_tuple = [arrivals_tuple[(i-1)*div(length(arrivals_tuple), s)+1:i*div(length(arrivals_tuple), s)] for i in 1:s]
        push!(arrivals, arrivals_tuple)
    end
    
    return areas_dict, baggage_df, shifts_df, breaks_df, overtime_df, parameters, travel, arrivals, cert_list
end

function create_area_dictionary(area)
    area_dict = Dict()
    
    nodes = []
    
    max_stations = parse.(Int, split(area["Max Stations"], ','))
    all_stations = []
    
    resources_lookup = parse.(Int, split(area["Station Resources"], ','))
    all_station_resources = []
    
    rates_lookup = parse.(Float64, split(area["Station Rate"], ','))
    all_station_rates = []
    
    for stations ∈ max_stations
        push!(all_station_resources, vcat([0], resources_lookup[1:stations]))
        resources_lookup = resources_lookup[stations+1:end]

        push!(all_station_rates, vcat([0.0], rates_lookup[1:stations]))
        rates_lookup = rates_lookup[stations+1:end]
    end

    if typeof(area["Buffer Capacity"]) == String
        capacity_lookup = parse.(Int, split(area["Buffer Capacity"], ','))
    else
        capacity_lookup = [convert(Int, round(area["Buffer Capacity"]))]
    end

    all_node_buffer_capacities = []
    for node ∈ 1:area["Service Nodes"]
        push!(nodes, node)

        push!(all_node_buffer_capacities, capacity_lookup[node])

        stations = []
        # Determine the processing rate based on the number of stations open
        for station ∈ 0:max_stations[node]
            push!(stations, station)
        end
        push!(all_stations, stations)
    end

    area_dict["Nodes"] = nodes
    area_dict["Stations"] = all_stations
    area_dict["Rates"] = all_station_rates
    area_dict["Resources"] = all_station_resources
    area_dict["Buffer Capacities"] = all_node_buffer_capacities
    area_dict["Period Opened"] = area["Open"]
    area_dict["Period Closed"] = area["Close"]
    
    return area_dict
end

function substring_to_character(s::AbstractString, c::AbstractString)
    return s[1:findfirst(c, s)[1]-1]
end

# For processing the solution flow data outputs
# Input a solution dataframe, flow variable name, and a vertex lookup dictionary
# Output a flow dataframe with flow decisions translated from id vertexes to the actual locations
function create_solution_flow(solution_df, flow_variable_name, vertex_lookup_dict, cert = "")
    if cert != ""
        raw_flow_df = filter(row -> row.variable_name == flow_variable_name && row.index_3 == cert, solution_df)
    else
        raw_flow_df = filter(row -> row.variable_name == flow_variable_name, solution_df)
    end

    flow_df = DataFrame(origin = Any[], destination = Any[], time_period_start = Any[], time_period_end = Any[], flow_quantity = Any[], shift_id = Any[], break_id = Any[], scenario = Any[], certification = Any[])
    for row ∈ eachrow(raw_flow_df)
        o = vertex_lookup_dict[row.index_1][4]
        d = vertex_lookup_dict[row.index_2][4]
        
        t_start = 0
        t_end = 0
        if o == "Off Duty" && d != "Off Duty"
            t_start = vertex_lookup_dict[row.index_2][3] - 1
            t_end = vertex_lookup_dict[row.index_2][3]
        elseif o != "Off Duty" && d == "Off Duty"
            t_start = vertex_lookup_dict[row.index_1][3]
            t_end = vertex_lookup_dict[row.index_1][3] + 1
        else
            t_start = vertex_lookup_dict[row.index_1][3]
            t_end = vertex_lookup_dict[row.index_2][3]
        end
        
        flow = row.value
        shiftid = vertex_lookup_dict[row.index_1][1]
        breakid = vertex_lookup_dict[row.index_1][2]
        if cert != ""
            s = row.index_4
        else
            s = row.index_3
        end
        push!(flow_df, [o, d, t_start, t_end, flow, shiftid, breakid, s, cert])
    end

    return(flow_df)
end

function remove_shifts_certifications(shifts_df)
    new_shifts_df = shifts_df[:, ["Shift ID", "Hired", "Start", "End"]]
    new_shifts_df[!, :"Split Shift ID"] = split.(new_shifts_df[!, :"Shift ID"], ".")
    # if there are two items after splitting (no AM/PM) then just take the first item
    # if there are three items after splitting (AM/PM) then take the first and third items
    new_shifts_df[!, :"Shift ID"] = map(new_shifts_df[:, :"Split Shift ID"]) do x
        if length(x) == 2
            return x[1]
        elseif length(x) == 3
            return x[1] * "." * x[3]
        else
            return missing
        end
    end

    new_shifts_df = combine(groupby(new_shifts_df, "Shift ID"), :Hired => sum, :Start => first, :End => last)

    rename!(new_shifts_df, ["Shift ID", "Hired", "Start", "End"])
    return new_shifts_df
end

function remove_breaks_certifications(breaks_df; fixed_breaks = false)
    breaks_df_copy = deepcopy(breaks_df)
    breaks_df_copy[!, :"Split Shift ID"] = split.(breaks_df_copy[!, :"Shift ID"], ".")
    breaks_df_copy[!, :"Shift ID"] = map(breaks_df_copy[:, :"Split Shift ID"]) do x
        if length(x) == 2
            return x[1]
        elseif length(x) == 3
            return x[1] * "." * x[3]
        else
            return missing
        end
    end

    if fixed_breaks
        new_breaks_df = combine(groupby(breaks_df_copy, ["Shift ID", "Break ID"]), :Start => first, :End => first, :Selected => sum)
    else
        new_breaks_df = combine(groupby(breaks_df_copy, ["Shift ID", "Break ID"]), :Start => first, :End => first)
    end

    # to force column to have type any
    temp_breaks = []
    for i in 1:nrow(new_breaks_df)
        if i%2 == 0
            push!(temp_breaks, 1)
        else
            push!(temp_breaks, [1,1])
        end    
    end

    new_breaks_df[!, :"Breaks"] = temp_breaks
    
    for row in eachrow(new_breaks_df)
        matched_row_index = findfirst(x -> x["Shift ID"] == row["Shift ID"] && x["Break ID"] == row["Break ID"], eachrow(breaks_df_copy))
        matched_row = breaks_df_copy[matched_row_index, :]
        row["Breaks"] = matched_row["Breaks"]
    end

    if fixed_breaks
        rename!(new_breaks_df, ["Shift ID", "Break ID", "Start", "End", "Selected", "Breaks"])
    else
        rename!(new_breaks_df, ["Shift ID", "Break ID", "Start", "End", "Breaks"])
    end
    
    return new_breaks_df
end

function remove_overtime_certifications(overtime_df)
    overtime_df_copy = deepcopy(overtime_df)
    overtime_df_copy[!, :"Split Shift ID"] = split.(overtime_df_copy[!, :"Shift ID"], ".")
    overtime_df_copy[!, :"Shift ID"] = map(overtime_df_copy[:, :"Split Shift ID"]) do x
        if length(x) == 2
            return x[1]
        elseif length(x) == 3
            return x[1] * "." * x[3]
        else
            return missing
        end
    end

    new_overtime_df = combine(groupby(overtime_df_copy, ["Shift ID", "Overtime ID"]), :Start => first, :End => first, :Cost => first)

    rename!(new_overtime_df, ["Shift ID", "Overtime ID", "Start", "End", "Cost"])
end

function create_fixed_breaks!(breaks_df, shifts_df; scenarios=1)
    breaks_df[!, :Selected] = zeros(Int, nrow(breaks_df))

    for s in 1:scenarios
        for shift in shifts_df[:, "Shift ID"]
            total_hired = filter(row -> row."Shift ID" == shift, shifts_df)[1, :"Hired"]
            break_scheds_of_shift = filter(:"Shift ID" => ==(shift), breaks_df)[:, "Break ID"]
            distributed_selections = zeros(Int, length(break_scheds_of_shift))
            for i in 1:total_hired
                break_schedule = break_scheds_of_shift[rand(1:end)]
                distributed_selections[break_schedule] += 1
            end

            for sched in break_scheds_of_shift
                mask = (breaks_df."Shift ID" .== shift) .& (breaks_df."Break ID" .== sched)
                breaks_df[mask, "Selected"] .= distributed_selections[sched]
            end
        end
    end
end