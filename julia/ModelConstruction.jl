using DataFrames, JuMP

function construct_model(
    model::Model,
    areas, baggage_df, shifts_df, breaks_df, overtime_df, parameters, arrivals,
    break_network_dict,
    overtime_network_dict,
    model_type,
    cert_list = [];
    initial_queues = false,
    half_day_delta_free_periods = 0,
    ignore_extreme_changes = false
    )

    time_periods = parameters["time_periods"]
    scenarios = parameters["scenarios"]
    ot_shift_fraction = parameters["fraction_shift_OT"]

    break_shifts = unique(breaks_df[:, "Shift ID"])
    overtime_shifts = unique(overtime_df[:, "Shift ID"])
    
    # ~~~~~~~~~~~~~~~~~~
    # variables
    # ~~~~~~~~~~~~~~~~~~
    @info("Adding variables")
    # config selected variables, with scenarios
    @info("x variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, x[area = keys(areas),
                            node = areas[area]["Nodes"],
                            stations_open = areas[area]["Stations"][node],
                            time = 1:time_periods,
                            scenario = 1:scenarios],
                            Bin)
    end

    # Fix the variables to config one if closed
    if model_type in [1, 2, 3, 4]
        @info("enforcing open and close periods")
        for area in keys(areas)
            for node in areas[area]["Nodes"]
                for scenario in 1:scenarios
                    # must be closed from first period to period opened
                    if areas[area]["Period Opened"] != 1
                        for time in 1:(areas[area]["Period Opened"]-1)
                            fix(x[area, node, 0, time, scenario], 1)
                        end
                    end

                    if areas[area]["Period Closed"] != parameters["time_periods"] + 1
                        for time in (areas[area]["Period Closed"]+1):parameters["time_periods"]
                            fix(x[area, node, 0, time, scenario], 1)
                        end
                    end
                end
            end
        end
    end

    # open and close penalty tracking, configurations change with configuration
    # equal to 1 if configuration k1 is chosen at time t-1 and k2 is chosen at time t
    @info("config changed variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, config_changed[area = keys(areas),
                                            node = areas[area]["Nodes"],
                                            stations_open_1 = areas[area]["Stations"][node],
                                            stations_open_2 = areas[area]["Stations"][node],
                                            time = 2:time_periods,
                                            scenario = 1:scenarios]>=0)
    end

    # rate variables, with scenarios
    @info("mu variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, mu[area = keys(areas),
                            node = areas[area]["Nodes"],
                            time = 1:time_periods,
                            scenario = 1:scenarios]>=0)
    end

    # actual passengers processed, with scenarios
    @info("c variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, c[area = keys(areas),
                            node = areas[area]["Nodes"],
                            time = 1:time_periods,
                            scenario = 1:scenarios]>=0)
    end

    # queue variables, with scenarios
    @info("Q variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, Q[area = keys(areas),
                            node = areas[area]["Nodes"],
                            time = 1:time_periods,
                            scenario = 1:scenarios]>=0)
    end

    # extreme change variables, with scenarios
    if !ignore_extreme_changes
        if half_day_delta_free_periods == 0
            @info("delta variables")
            if model_type in [1, 2, 3, 4]
                @variable(model, delta[area = keys(areas),
                                        node = areas[area]["Nodes"],
                                        station = areas[area]["Stations"][node],
                                        time = 1:time_periods,
                                        status = ["on","off"],
                                        scenario = 1:scenarios],
                                        Bin)
            end
        else
            @info("delta variables with extreme changes not enforced for $(half_day_delta_free_periods) periods")
            if model_type in [1, 2, 3, 4]
                @variable(
                    model, 
                    delta[area = 
                        keys(areas),
                        node = areas[area]["Nodes"],
                        station = areas[area]["Stations"][node],
                        time = half_day_delta_free_periods:time_periods,
                        status = ["on","off"],
                        scenario = 1:scenarios],
                    Bin
                )
            end
        end
    end

    # hiring variables, (for these models it is just overtime hiring)
    @info("h variables")
    if model_type in [10, 12]
        @variable(model, h[shift = shifts_df[:, "Shift ID"]] >=0, Int)
    end

    #break flow variables
    @info("break flow variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, break_flow[edge = break_network_dict["edges"], scenario = 1:scenarios]>=0, Int)
    end

    # break selection variables
    @info("break selection variables")
    if model_type in [1, 2, 3, 4]
        @variable(model, break_selection[shift = break_shifts,
                                break_schedule = filter(:"Shift ID"=> ==(shift), breaks_df)[:, "Break ID"],
                                scenario = 1:scenarios] >= 0, 
                                Int)
    end
                            
    # overtime flow variables, with scenarios
    @info("overtime flow variables")
    if model_type in [1, 3]
        @variable(model, overtime_flow[edge = overtime_network_dict["edges"], scenario = 1:scenarios] >=0, Int)
    end

    # overtime hiring variables
    @info("overtime hiring variables")
    if model_type in [1, 3]
        @variable(model, overtime_h[shift = overtime_shifts,
            overtime_shift = unique(filter(:"Shift ID"=>==(shift), overtime_df)[:, "Overtime ID"])]>=0, Int)
    end

    # ~~~~~~~~~~~~~~~~~~
    # objective
    # ~~~~~~~~~~~~~~~~~~

    if model_type in [1, 3]
        @info("Adding objective")
        @objective(model, Min, sum(parameters["cost_regularization"][1] * parameters["scenario_weights"][s] * Q[i, j, t, s]
                                    for (i, j, t, s) ∈ eachindex(Q))
                                + sum(parameters["cost_regularization"][2]
                                    * overtime_df[(overtime_df."Shift ID" .== shift) .& (overtime_df."Overtime ID" .== otshift), :"Cost"][1] # this is accessing the otshift cost
                                    * overtime_h[shift, otshift] for (shift, otshift) ∈ eachindex(overtime_h))
                                + sum(parameters["config_cost"] * k * x[i, j, k, t, s] for i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ 1:time_periods, s ∈ 1:scenarios))
    end

    if model_type in [2, 4]
        @info("Adding objective")
        @objective(model, Min, sum(parameters["cost_regularization"][1] * parameters["scenario_weights"][s] * Q[i, j, t, s] for (i, j, t, s) ∈ eachindex(Q))
                                + sum(parameters["config_cost"] * k * x[i, j, k, t, s] for i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ 1:time_periods, s ∈ 1:scenarios))
    end

    # ~~~~~~~~~~~~~~~~~~
    # constraints
    # ~~~~~~~~~~~~~~~~~~
    if model_type in [1, 2, 3, 4]
        @info("Adding single selection constraints")
        @constraint(model, single_config[i ∈ keys(areas), j ∈ areas[i]["Nodes"], t ∈ 1:time_periods, s ∈ 1:scenarios],
                        sum(x[i, j, k, t, s] for k ∈ areas[i]["Stations"][j]) == 1)
    end
    
    if model_type in [1, 2, 3, 4]             
        @info("Adding capture rate constraints")
        for i ∈ keys(areas)
            for j ∈ areas[i]["Nodes"]
                for t ∈ 1:time_periods
                    for s ∈ 1:scenarios
                        if t == 1
                            #k+1 is necessary for rates since 0 stations is first but 1 is the first index
                            @constraint(model, mu[i,j,t,s]
                                == sum(x[i,j,k,t,s]*areas[i]["Rates"][j][k+1] for k ∈ areas[i]["Stations"][j]) # captures the nominal rate
                                - sum(parameters["ramp_penalty"] * (areas[i]["Rates"][j][k_1+1] - areas[i]["Rates"][j][k_2+1]) * config_changed[i,j,k_1,k_2,t+1,s] # t has configuration k1 and t+1 has configuration k2 and rate(k1) > rate(k2)
                                    for k_1 ∈ areas[i]["Stations"][j], k_2 ∈ areas[i]["Stations"][j]
                                        if areas[i]["Rates"][j][k_1+1] > areas[i]["Rates"][j][k_2+1]), #checks if the next period rate is going down
                                base_name = "capture_rate_$(i)_$(j)_$(t)_$(s)")
                        elseif t == time_periods
                            @constraint(model, mu[i,j,t,s]
                                == sum(x[i,j,k,t,s]*areas[i]["Rates"][j][k+1] for k ∈ areas[i]["Stations"][j])
                                - sum(parameters["ramp_penalty"] * (areas[i]["Rates"][j][k_2+1] - areas[i]["Rates"][j][k_1+1]) * config_changed[i,j,k_1,k_2,t,s] # t-1 has configuration k1 and t has configuration k2 and rate(k1) < rate(k2)
                                    for k_1 ∈ areas[i]["Stations"][j], k_2 ∈ areas[i]["Stations"][j]
                                        if areas[i]["Rates"][j][k_1+1] < areas[i]["Rates"][j][k_2+1]), #checks if this period rate is going up
                                base_name = "capture_rate_$(i)_$(j)_$(t)_$(s)")
                        else
                            @constraint(model, mu[i,j,t,s]
                                == sum(x[i,j,k,t,s]*areas[i]["Rates"][j][k+1] for k ∈ areas[i]["Stations"][j])
                                # the if condition checks if the next period rate is going down
                                - sum(parameters["ramp_penalty"] * (areas[i]["Rates"][j][k_1+1] - areas[i]["Rates"][j][k_2+1]) * config_changed[i,j,k_1,k_2,t+1,s]
                                    for k_1 ∈ areas[i]["Stations"][j], k_2 ∈ areas[i]["Stations"][j]
                                        if areas[i]["Rates"][j][k_1+1] > areas[i]["Rates"][j][k_2+1])
                                # same as above but if checks if the rate is going up from last period
                                - sum(parameters["ramp_penalty"] * (areas[i]["Rates"][j][k_2+1] - areas[i]["Rates"][j][k_1+1]) * config_changed[i,j,k_1,k_2,t,s]
                                    for k_1 ∈ areas[i]["Stations"][j], k_2 ∈ areas[i]["Stations"][j]
                                        if areas[i]["Rates"][j][k_1+1] < areas[i]["Rates"][j][k_2+1]),
                                base_name = "capture_rate_$(i)_$(j)_$(t)_$(s)")
                        end
                    end
                end
            end
        end
    end

    if model_type in [1, 2, 3, 4]
        @info("Adding configuration change tracking constraints")
        for area ∈ keys(areas)
            for node ∈ areas[area]["Nodes"]
                for stations_open_1 ∈ areas[area]["Stations"][node]
                    for stations_open_2 ∈ areas[area]["Stations"][node]
                        for t ∈ 2:time_periods
                            for s ∈ 1:scenarios
                                @constraint(model, x[area, node, stations_open_1, t-1, s] + x[area, node, stations_open_2, t, s] - 1
                                                <= config_changed[area, node, stations_open_1, stations_open_2, t, s],
                                                base_name = "config_changed_1_$(area)_$(node)_$(stations_open_1)_$(stations_open_2)_$(t)_$(s)")
                                
                                @constraint(model, x[area, node, stations_open_1, t-1, s] >= config_changed[area, node, stations_open_1, stations_open_2, t, s],
                                                base_name = "config_changed_2_$(area)_$(node)_$(stations_open_1)_$(stations_open_2)_$(t)_$(s)")
                                            
                                @constraint(model, x[area, node, stations_open_2, t, s] >= config_changed[area, node, stations_open_1, stations_open_2, t, s],
                                                base_name = "config_changed_3_$(area)_$(node)_$(stations_open_1)_$(stations_open_2)_$(t)_$(s)")
                            end
                        end
                    end
                end
            end
        end
    end
    
    if model_type in [1, 2, 3, 4]
        @info("Adding queue buffer constraints")
        # Only add if not at the first area
        for i ∈ keys(areas), j ∈ areas[i]["Nodes"], t ∈ 1:time_periods, s ∈ 1:scenarios
            if i >= 1
                # j is the number of servers opened for the TSA model
                @constraint(model, Q[i,j,t,s]
                    <= sum(areas[i]["Buffer Capacities"][j] * j * x[i,j,k,t,s] for k ∈ areas[i]["Stations"][j]),
                base_name = "queue_buffer_$(i)_$(j)_$(t)_$(s)")
            end
        end
    end
    
    # ~~~
    # Can't process more than available
    # ~~~
    if model_type in [1, 2, 3, 4]
        @info("Adding maximum allowed to process constraints")
        # for node 1, time period 1
        @constraint(model, processed_le_arrivals_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                        arrivals[1][s][1] >= c[i,1,1,s]);
        # for node 1, time period > 1
        @constraint(model, processed_le_Q_arrivals_n1[i ∈ keys(areas), t ∈ 2:time_periods, s ∈ 1:scenarios],
                        Q[i,1,t-1,s] + arrivals[t][s][i] >= c[i,1,t,s])
        # for nodes not 1, time period 1
        @constraint(model, processed_le_arrivals_t1[i ∈ keys(areas), j ∈ 2:maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                        c[i,j-1,1,s] >= c[i,j,1,s])
        # for nodes not 1, time period > 1
        @constraint(model, processed_le_Q_arrivals[i ∈ keys(areas), j ∈ 2:maximum(areas[i]["Nodes"]), t ∈ 2:time_periods, s ∈ 1:scenarios],
                        Q[i,j,t-1,s] + c[i,j-1,t,s] >= c[i,j,t,s])
    end
    
    # ~~~
    # Inventory queue tracking constraints
    # ~~~
    if model_type in [1, 2, 3, 4]
        @info("Adding inventory queue tracking constraints")
        if initial_queues == false
            # For node 1, time period 1
            @constraint(model, queue_tracking_t1_n1[i ∈ keys(areas), s∈1:scenarios],
                            arrivals[1][s][1] - c[i,1,1,s] == Q[i,1,1,s])
            # For nodes not 1, time period 1
            @constraint(model, queue_tracking_t1[i ∈ keys(areas), j ∈ 2:maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                            c[i,j-1,1,s] - c[i,j,1,s] == Q[i,j,1,s])
        else
            # For node 1, time period 1
            @constraint(model, queue_tracking_t1_n1[i ∈ keys(areas), s∈1:scenarios],
                            arrivals[1][s][1] + initial_queues[i,1] - c[i,1,1,s] == Q[i,1,1,s])
            # For nodes not 1, time period 1
            @constraint(model, queue_tracking_t1[i ∈ keys(areas), j ∈ 2:maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                            c[i,j-1,1,s] + initial_queues[i,j] - c[i,j,1,s] == Q[i,j,1,s])
        end
        
        # For node 1, time period > 1
        @constraint(model, queue_tracking_n1[i ∈ keys(areas), t ∈ 2:time_periods, s ∈ 1:scenarios],
            Q[i,1,t-1,s] + arrivals[t][s][i] - c[i, 1, t, s] == Q[i,1,t,s])
        # For nodes not 1, time period > 1
        @constraint(model, queue_tracking[i ∈ keys(areas), j ∈ 2:maximum(areas[i]["Nodes"]), t ∈ 2:time_periods, s ∈ 1:scenarios],
            Q[i,j,t-1,s] + c[i,j-1,t,s] - c[i,j,t,s] == Q[i,j,t,s])
    end

    # ~~~
    # Hyperplane processing constraints
    # ~~~
    if model_type in [1, 2, 3, 4]
        @info("Adding hyperplane queue tracking constraints")
        if initial_queues == false
            # ML 1 node 1, time period 1
            @constraint(model, ml_1_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_1"]*mu[i,1,1,s]+parameters["β_2"]*arrivals[1][s][1] >= c[i,1,1,s])
            # ML 2 node 1, time period 1
            @constraint(model, ml_2_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_4"]*mu[i,1,1,s]+parameters["β_5"]*arrivals[1][s][1] >= c[i,1,1,s])
            # ML 3 node 1, time period 1
            @constraint(model, ml_3_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_7"]*mu[i,1,1,s]+parameters["β_8"]*arrivals[1][s][1] >= c[i,1,1,s])

            # ML 1 nodes not 1, time period 1
            @constraint(model, ml_1_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_1"]*mu[i,j,1,s]+parameters["β_2"]*c[i,j-1,1,s] >= c[i,j,1,s])
            # ML 2 nodes not 1, time period 1
            @constraint(model, ml_2_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_4"]*mu[i,j,1,s]+parameters["β_5"]*c[i,j-1,1,s] >= c[i,j,1,s])
            # ML 3 nodes not 1, time period 1
            @constraint(model, ml_3_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_7"]*mu[i,j,1,s]+parameters["β_8"]*c[i,j-1,1,s] >= c[i,j,1,s])
    
        else
            # ML 1 node 1, time period 1
            @constraint(model, ml_1_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_0"]*initial_queues[i,1]+parameters["β_1"]*mu[i,1,1,s]+parameters["β_2"]*arrivals[1][s][1] >= c[i,1,1,s])
            # ML 2 node 1, time period 1
            @constraint(model, ml_2_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_3"]*initial_queues[i,1]+parameters["β_4"]*mu[i,1,1,s]+parameters["β_5"]*arrivals[1][s][1] >= c[i,1,1,s])
            # ML 3 node 1, time period 1
            @constraint(model, ml_3_t1_n1[i ∈ keys(areas), s ∈ 1:scenarios],
                parameters["β_6"]*initial_queues[i,1]+parameters["β_7"]*mu[i,1,1,s]+parameters["β_8"]*arrivals[1][s][1] >= c[i,1,1,s])

            # ML 1 nodes not 1, time period 1
            @constraint(model, ml_1_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_0"]*initial_queues[i,j]+parameters["β_1"]*mu[i,j,1,s]+parameters["β_2"]*c[i,j-1,1,s] >= c[i,j,1,s])
            # ML 2 nodes not 1, time period 1
            @constraint(model, ml_2_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_3"]*initial_queues[i,j]+parameters["β_4"]*mu[i,j,1,s]+parameters["β_5"]*c[i,j-1,1,s] >= c[i,j,1,s])
            # ML 3 nodes not 1, time period 1
            @constraint(model, ml_3_t1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), s ∈ 1:scenarios],
                parameters["β_6"]*initial_queues[i,j]+parameters["β_7"]*mu[i,j,1,s]+parameters["β_8"]*c[i,j-1,1,s] >= c[i,j,1,s])
        end
        
        # ML 1 node 1, time period > 1
        @constraint(model, ml_1_n1[i ∈ keys(areas), t ∈ 2:time_periods, s ∈ 1:scenarios],
                        parameters["β_0"]*Q[i,1,t-1,s]+parameters["β_1"]*mu[i,1,t,s]+parameters["β_2"]*arrivals[t][s][1] >= c[i,1,t,s])
        # ML 2 node 1, time period > 1
        @constraint(model, ml_2_n1[i ∈ keys(areas), t ∈ 2:time_periods, s ∈ 1:scenarios],
                        parameters["β_3"]*Q[i,1,t-1,s]+parameters["β_4"]*mu[i,1,t,s]+parameters["β_5"]*arrivals[t][s][1] >= c[i,1,t,s])
        # ML 3 node 1, time period > 1
        @constraint(model, ml_3_n1[i ∈ keys(areas), t ∈ 2:time_periods, s ∈ 1:scenarios],
                        parameters["β_6"]*Q[i,1,t-1,s]+parameters["β_7"]*mu[i,1,t,s]+parameters["β_8"]*arrivals[t][s][1] >= c[i,1,t,s])
        # ML 1 nodes not 1, time period > 1
        @constraint(model, ml_1[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), t ∈ 2:time_periods, s ∈ 1:scenarios],
            parameters["β_0"]*Q[i,j,t-1,s]+parameters["β_1"]*mu[i,j,t,s]+parameters["β_2"]*c[i,j-1,t,s] >= c[i,j,t,s])
        # ML 2 nodes not 1, time period > 1
        @constraint(model, ml_2[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), t ∈ 2:time_periods, s ∈ 1:scenarios],
            parameters["β_3"]*Q[i,j,t-1,s]+parameters["β_4"]*mu[i,j,t,s]+parameters["β_5"]*c[i,j-1,t,s] >= c[i,j,t,s])
        # ML 3 nodes not 1, time period > 1
        @constraint(model, ml_3[i ∈ keys(areas), j ∈ maximum(areas[i]["Nodes"]), t ∈ 2:time_periods, s ∈ 1:scenarios],
            parameters["β_6"]*Q[i,j,t-1,s]+parameters["β_7"]*mu[i,j,t,s]+parameters["β_8"]*c[i,j-1,t,s] >= c[i,j,t,s])
    end

    # ~~~
    # Extreme change
    # ~~~
    if !ignore_extreme_changes
        if half_day_delta_free_periods == 0
            if model_type in [1, 2, 3, 4]
                @info("Adding extreme change constraints")
                @constraint(model, extreme_change_1[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ 1:(time_periods-1), s ∈ 1:scenarios],
                    x[i,j,k,t,s]-x[i,j,k,t+1,s]+delta[i,j,k,t+1,"on",s]-delta[i,j,k,t+1,"off",s]==0)
                
                @constraint(model, extreme_change_2[i ∈ keys(areas), j ∈ areas[i]["Nodes"], t ∈ 1:(time_periods-parameters["M"]), m ∈ 1:parameters["M"], s ∈ 1:scenarios, u ∈ ["on", "off"], v ∈ ["on", "off"]],
                    sum(delta[i,j,k,t,u,s] for k ∈ areas[i]["Stations"][j]) <= 1 - sum(delta[i,j,k,(t+m),v,s] for k ∈ areas[i]["Stations"][j]))

                @constraint(model, extreme_change_3[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ (time_periods-parameters["M"]+1):time_periods, u ∈ ["on", "off"], s ∈ 1:scenarios],
                    delta[i,j,k,t,u,s]==0)
                
                @constraint(model, extreme_change_4[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ 2:parameters["M"], u ∈ ["on", "off"], s ∈ 1:scenarios],
                    delta[i,j,k,t,u,s]==0)
            end
        else
            if model_type in [1, 2, 3, 4]
                @info("Adding extreme change constraints with $(half_day_delta_free_periods) periods of nonenforcement")
                @constraint(
                    model,
                    extreme_change_1[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ half_day_delta_free_periods:(time_periods-1), s ∈ 1:scenarios],
                    x[i,j,k,t,s]-x[i,j,k,t+1,s] + delta[i,j,k,t+1,"on",s] - delta[i,j,k,t+1,"off",s]
                    ==
                    0
                )

                @constraint(
                    model,
                    extreme_change_2[i ∈ keys(areas), j ∈ areas[i]["Nodes"], t ∈ half_day_delta_free_periods:(time_periods-parameters["M"]), m ∈ 1:parameters["M"], s ∈ 1:scenarios, u ∈ ["on", "off"], v ∈ ["on", "off"],
                    k ∈ areas[i]["Stations"][j]],
                    sum(delta[i,j,k,t,u,s] for k ∈ areas[i]["Stations"][j]) <= 1 - sum(delta[i,j,k,(t+m),v,s] for k ∈ areas[i]["Stations"][j])
                )

                @constraint(
                    model,
                    extreme_change_3[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j],
                                        t ∈ (max(time_periods-parameters["M"]+1, half_day_delta_free_periods)):time_periods, u ∈ ["on", "off"], s ∈ 1:scenarios],
                    delta[i,j,k,t,u,s] == 0
                )

                if parameters["M"] > half_day_delta_free_periods
                    @constraint(
                        model,
                        extreme_change_4[i ∈ keys(areas), j ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j], t ∈ half_day_delta_free_periods:(parameters["M"]), u ∈ ["on", "off"], s ∈ 1:scenarios],
                        delta[i,j,k,t,u,s] == 0
                    )
                end
            end
        end
    end

    # ~~~
    # Break Network Constraints
    # ~~~
    if model_type in [1, 2, 3, 4]
        @info("Adding break selection constraints")
        @constraint(model, break_selection_enforced[shift ∈ break_shifts, s ∈ 1:scenarios],
                sum(break_selection[shift, break_schedule, s]
                    for break_schedule ∈ filter(:"Shift ID"=> ==(shift), breaks_df)[:, "Break ID"])
                == filter(row -> row."Shift ID" == shift, shifts_df)[1, :"Hired"])
    end

    if model_type in [1, 2, 3, 4]
        @info("Adding break flow balance constraints")
        # ensures that the flow into a node is equal to the flow out of a node for all nodes except the sources and sinks
        @constraint(model, break_flow_balance[n ∈ [break_network_dict["internal_vertices"]; break_network_dict["breaks"]; break_network_dict["baggage"]],
        s ∈ 1:scenarios],
            sum(break_flow[[origin, n], s] for origin ∈ break_network_dict["flow_in_dict"][n])
            - sum(break_flow[[n, destination], s] for destination ∈ break_network_dict["flow_out_dict"][n])==0)

        @info("Adding break source flow constraints")
        @constraint(model, break_source_flow[n ∈ break_network_dict["sources"], s ∈ 1:scenarios],
            sum(break_flow[[n, destination], s] for destination ∈ break_network_dict["flow_out_dict"][n])
            == break_selection[break_network_dict["vertex_lookup_dict"][n][2],break_network_dict["vertex_lookup_dict"][n][3], s])
            # the second element of a node is the shift_id, the third element is the break_id
        
        @info("Adding break sink flow constraints")
        @constraint(model, break_sink_flow[n ∈ break_network_dict["sinks"], s ∈ 1:scenarios],
            sum(break_flow[[origin, n], s] for origin ∈ break_network_dict["flow_in_dict"][n])
            == break_selection[break_network_dict["vertex_lookup_dict"][n][2],break_network_dict["vertex_lookup_dict"][n][3], s])
    end

    # ~~~
    # Overtime Network Constraints
    # ~~~
    if model_type in [1, 3]
        @info("Adding overtime selection constraints")
        for shift ∈ overtime_shifts
            if nrow(filter(row -> row."Shift ID" == shift, shifts_df)) != 0
                @constraint(model,
                    sum(overtime_h[shift, ot_schedule] for ot_schedule ∈ filter(:"Shift ID"=> ==(shift), overtime_df)[:, "Overtime ID"])
                    <= ot_shift_fraction * filter(row -> row."Shift ID" == shift, shifts_df)[1, "Hired"],
                    base_name = "overtime_selection_$(shift)")
            end
        end
    end

    if model_type in [1, 3]
        @info("Adding overtime flow balance constraints")
        @constraint(model, overtime_flow_balance[n ∈ [overtime_network_dict["internal_vertices"]; overtime_network_dict["baggage"]], s ∈ 1:scenarios],
            sum(overtime_flow[[origin, n], s] for origin ∈ overtime_network_dict["flow_in_dict"][n])
            - sum(overtime_flow[[n, destination], s] for destination ∈ overtime_network_dict["flow_out_dict"][n])==0)
        
        @info("Adding overtime source flow constraints")
        @constraint(model, overtime_source_flow[n ∈ overtime_network_dict["sources"], s ∈ 1:scenarios],
            sum(overtime_flow[[n, destination], s] for destination ∈ overtime_network_dict["flow_out_dict"][n])
            == overtime_h[overtime_network_dict["vertex_lookup_dict"][n][2],overtime_network_dict["vertex_lookup_dict"][n][3]])
            # the second element of a node is the shift_id, the third element is the overtime_id
        
        @info("Adding overtime sink flow constraints")
        @constraint(model, overtime_sink_flow[n ∈ overtime_network_dict["sinks"], s ∈ 1:scenarios],
            sum(overtime_flow[[origin, n], s] for origin ∈ overtime_network_dict["flow_in_dict"][n])
            == overtime_h[overtime_network_dict["vertex_lookup_dict"][n][2], overtime_network_dict["vertex_lookup_dict"][n][3]])
    end

    # ~~~
    # Sufficient labor
    # ~~~

    if model_type in [1]
        # TODO: add these constraints in one nested for loop to optimize the code
        @info("Adding sufficient certified labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, cert ∈ cert_list, s ∈ 1:scenarios
            # There is flow into the area and the flow has a certification that covers the flow in
            if haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
                # the find first part returns the row index of the shift, the dict[edge[1]][2] returns the shift id, and the whole thing returns true or false if that shift has that cert
                break_edges = [edge for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(break_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                # don't include break flow if there are no edges
                include_break_flow = !isempty(break_edges)
            else
                include_break_flow = false
            end

            if haskey(overtime_network_dict["area_node_time_flowin_dict"], (i,j,t))
                overtime_edges = ""
                overtime_edges = [edge for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(overtime_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                # don't include OT flow if there are no edges
                include_overtime_flow = !isempty(overtime_edges)
            else
                include_overtime_flow = false
            end 
            
            # k+1 is used since there is a configuration 0 but the area certification requirement is indexed from 1
            if include_break_flow && include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    + sum(overtime_flow[edge, s] for edge ∈ overtime_edges)
                    >= sum(areas[i][cert][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_ ]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(cert)_$(s)")
            elseif include_break_flow && !include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    >= sum(areas[i][cert][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(cert)_$(s)")
            elseif include_overtime_flow && !include_break_flow
                @constraint(model, 
                    sum(overtime_flow[edge, s] for edge ∈ overtime_edges)
                    >= sum(areas[i][cert][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(cert)_$(s)")
            end
        end

        @info("Adding sufficient total labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            include_overtime_flow = haskey(overtime_network_dict["area_node_time_flowin_dict"], (i,j,t))
            # if both keys exist in the dictionary then include both break flow and OT flow
            if include_break_flow && include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    + sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            elseif include_break_flow && !include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            elseif include_overtime_flow && !include_break_flow
                @constraint(model, 
                    sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            end
        end

        @info("Adding sufficient baggage constraints")
        for i ∈ [length(keys(areas))+1], j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            cert = "Bag"
            # There is flow into the area and the flow has a certification that covers the flow in
            if haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
                # the find first part returns the row index of the shift, the dict[edge[1]][2] returns the shift id, and the whole thing returns true or false if that shift has that cert
                break_edges = [edge for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(break_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                # don't include break flow if there are no edges
                include_break_flow = !isempty(break_edges)
            else
                include_break_flow = false
            end

            if haskey(overtime_network_dict["area_node_time_flowin_dict"], (i,j,t))
                overtime_edges = [edge for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(overtime_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                # don't include OT flow if there are no edges
                include_overtime_flow = !isempty(overtime_edges)
            else
                include_overtime_flow = false
            end

            if include_break_flow && include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    + sum(overtime_flow[edge, s] for edge ∈ overtime_edges)
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            elseif include_break_flow && !include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            elseif include_overtime_flow && !include_break_flow
                @constraint(model, 
                    sum(overtime_flow[edge, s] for edge ∈ overtime_edges)
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            end
        end
    end

    # Sufficient labor when routing only goes to service areas and not service nodes
    if model_type in [2]
        # TODO: add these constraints in one nested for loop to optimize code
        @info("Adding sufficient certified labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, cert ∈ cert_list, s ∈ 1:scenarios
            if haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
                break_edges = [edge for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(break_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                include_break_flow = !isempty(break_edges)
            else
                include_break_flow = false
            end
            
            if include_break_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    >= sum(areas[i][cert][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(cert)_$(s)")
            end
        end

        @info("Adding sufficient total labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            if include_break_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            end
        end

        @info("Adding sufficient baggage constraints")
        for i ∈ [length(keys(areas))+1], j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            cert = "Bag"
            if haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
                break_edges = [edge for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t] if shifts_df[findfirst(isequal(break_network_dict["vertex_lookup_dict"][edge[1]][2]), shifts_df."Shift ID"), "Cert $(cert)"]]
                include_break_flow = !isempty(break_edges)
            else
                include_break_flow = false
            end

            if include_break_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_edges)
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            end
        end
            
    end

    if model_type in [3]
        @info("Adding sufficient total labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            include_overtime_flow = haskey(overtime_network_dict["area_node_time_flowin_dict"], (i,j,t))
            # if both keys exist in the dictionary then include both break flow and OT flow
            if include_break_flow && include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    + sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            elseif include_break_flow && !include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            elseif include_overtime_flow && !include_break_flow
                @constraint(model, 
                    sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            end
        end

        @info("Adding sufficient baggage constraints")
        for i ∈ [length(keys(areas))+1], j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            include_overtime_flow = haskey(overtime_network_dict["area_node_time_flowin_dict"], (i,j,t))
            # if both keys exist in the dictionary then include both break flow and OT flow
            if include_break_flow && include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    + sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            elseif include_break_flow && !include_overtime_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            elseif include_overtime_flow && !include_break_flow
                @constraint(model, 
                    sum(overtime_flow[edge, s] for edge ∈ overtime_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            end
        end
    end

    if model_type in [4]
        @info("Adding sufficient total labor constraints")
        for i ∈ keys(areas), j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            if include_break_flow 
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= sum(areas[i]["Resources"][j_][k+1] * x[i, j_, k, t, s] for j_ ∈ areas[i]["Nodes"], k ∈ areas[i]["Stations"][j_]),
                    base_name = "sufficient_labor_$(i)_$(j)_$(t)_$(s)")
            end
        end
    
        @info("Adding sufficient baggage constraints")
        for i ∈ [length(keys(areas))+1], j ∈ [1], t ∈ 1:time_periods, s ∈ 1:scenarios
            include_break_flow = haskey(break_network_dict["area_node_time_flowin_dict"], (i,j,t))
            if include_break_flow
                @constraint(model, 
                    sum(break_flow[edge, s] for edge ∈ break_network_dict["area_node_time_flowin_dict"][i,j,t])
                    >= baggage_df[!, "Needs"][t],
                    base_name = "sufficient_baggage_labor_$(t)_$(s)")
            end
        end
    end
end