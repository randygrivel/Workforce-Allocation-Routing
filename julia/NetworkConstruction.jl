using DataFrames

function construct_network_breaks_area(breaks_df, areas, traveling)
    vertices = DataFrame(type = String[], shiftid = Any[], breakid = Any[], t = Int[], area = Any[], node = Any[])
    edges = DataFrame(overtex = Array[], dvertex = Array[])
    serialized_baggage = []
    serialized_sources = []
    serialized_sinks = []
    serialized_breaks = []
    serialized_internal = []
    serialized_edges = []
    vertex_lookup = Dict()
    id_lookup = Dict()
    flow_in = Dict()
    flow_out = Dict()
    area_node_time_flowin = Dict()
    id = 1

    for break_schedule in eachrow(breaks_df)
        shift_id = break_schedule["Shift ID"]
        break_id = break_schedule["Break ID"]
        break_schedule_start = round(Int, break_schedule["Start"])
        break_schedule_end = round(Int, break_schedule["End"])
        
        # create source vertex
        vertex = ["source", shift_id, break_id, break_schedule_start, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sources, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_out dictionary for the source vertex
        flow_out[id] = []
        id += 1

        # create sink vertex
        vertex = ["sink", shift_id, break_id, break_schedule_end, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sinks, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_in dictionary for the sink vertex
        flow_in[id] = []
        id += 1

        if break_schedule["Breaks"] === missing
            breaks = []
        else
            breaks = break_schedule["Breaks"]
        end

        for t ∈ break_schedule_start:(break_schedule_end-1)
            current_period_is_break = t in breaks 
            next_period_is_break = (t + 1) in breaks

            # add baggage vertex
            baggage_area = length(keys(areas)) + 1
            vertex = ["baggage", shift_id, break_id, t, baggage_area, 1]
            push!(vertices, vertex)
            push!(serialized_baggage, id)
            vertex_lookup[id] = vertex
            id_lookup[vertex] = id
            flow_in[id] = []
            flow_out[id] = []
            id += 1
            area_node_time_flowin[baggage_area, 1, t] = []


            for area ∈ keys(areas)
                node = 1
                # instantiate area node time flowin dictionary
                area_node_time_flowin[area, node, t] = []
                # add internal vertices only when not in a break period
                if !current_period_is_break
                    vertex = ["internal", shift_id, break_id, t, area, node]
                    push!(vertices, vertex)
                    push!(serialized_internal, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1
                elseif current_period_is_break
                    vertex = ["break", shift_id, break_id, t, area, -1]
                    push!(vertices, vertex)
                    push!(serialized_breaks, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1

                    if area == 1
                        vertex = ["break", shift_id, break_id, t, baggage_area, -1]
                        push!(vertices, vertex)
                        push!(serialized_baggage, id)
                        vertex_lookup[id] = vertex
                        id_lookup[vertex] = id
                        flow_in[id] = []
                        flow_out[id] = []
                        id += 1
                    end
                end
                
                # TODO: consider the case there are breaks at the beginning or end to account for overnight shifts.
                
                # add source edges, assumes no break at beginning of shift
                if t == break_schedule_start
                    push!(edges, [["source", shift_id, break_id, t, -1, -1],["internal", shift_id, break_id, t, area, node]]) 
                    if area == 1
                        push!(edges, [["source", shift_id, break_id, t, -1, -1],["baggage", shift_id, break_id, t, baggage_area, node]])
                    end
                end

                # add sink edges, assumes no break at end of shift
                if t == break_schedule_end - 1
                    push!(edges, [["internal", shift_id, break_id, t, area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    if area == 1
                        push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    end
                end

                if current_period_is_break || next_period_is_break # add break edges if current or next period is a break
                    if !current_period_is_break && next_period_is_break # starting break next period
                        push!(edges, [["internal", shift_id, break_id, t, area, node], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    elseif current_period_is_break && !next_period_is_break # ending break this period
                        # allow travel to other areas but take time to travel to those areas
                        for end_area ∈ keys(areas)
                            travel_end = t + traveling[[[area, node],[end_area, node]]]
                            if travel_end < break_schedule_end
                                push!(edges, [["break", shift_id, break_id, t, area, -1], ["internal", shift_id, break_id, travel_end, end_area, node]])
                            end

                            if area == 1
                                travel_end = t + 1
                                if travel_end < break_schedule_end
                                    if end_area == 1
                                        push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["baggage", shift_id, break_id, travel_end, baggage_area, node]])
                                    end
                                    push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["internal", shift_id, break_id, travel_end, end_area, node]])
                                end
                            end
                        end
                    elseif current_period_is_break && next_period_is_break # consecutive breaks
                        push!(edges, [["break", shift_id, break_id, t, area, -1], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    end
                else # add normal edges otherwise
                    for end_area ∈ keys(areas)
                        travel_end = t + traveling[[[area, node],[end_area, node]]]
                        next_break_index = findfirst(breaks .> t)
                        

                        if isnothing(next_break_index) # no more breaks left
                            if travel_end < break_schedule_end # travel isn't beyond shift
                                push!(edges, [["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, end_area, node]])
                            end
                        elseif travel_end < breaks[next_break_index] && travel_end < break_schedule_end # travel isn't to or beyond break and isn't beyond shift
                            push!(edges,[["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, end_area, node]])
                        end
                    end

                    # add baggage edges
                    baggage_travel_end = t + 1
                    next_break_index = findfirst(breaks .> t)
                    if isnothing(next_break_index) # no more breaks left
                        if baggage_travel_end < break_schedule_end
                            if area == 1
                                push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                            end
                            push!(edges, [["internal", shift_id, break_id, t, area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["internal", shift_id, break_id, baggage_travel_end, area, node]])
                        end
                    elseif baggage_travel_end < breaks[next_break_index] && baggage_travel_end < break_schedule_end
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                            
                        end
                        push!(edges, [["internal", shift_id, break_id, t, area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                        push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["internal", shift_id, break_id, baggage_travel_end, area, node]])
                    end
                end
            end
        end
    end
    
    # TODO: rename the flow in to something that makes more sense, like preceding neighbors
    # TODO: do the same for flow out
    # TODO: to optimize, modify the construction loop and place this in it
    for edge ∈ eachrow(edges)
        origin_id = id_lookup[edge[1]]
        destination_id = id_lookup[edge[2]]
        serialized_edge = [origin_id, destination_id]
        push!(serialized_edges, serialized_edge)
        # adds the origin to the list of nodes that the destination receives flow from
        flow_in[destination_id] = [flow_in[destination_id]; origin_id]
        # adds the destination to the list of nodes that the origin flows to
        flow_out[origin_id] = [flow_out[origin_id]; destination_id]
        # takes the current area node time dictionary and adds the origin that flow into it
        if edge[2][1] == "internal" || edge[2][1] == "baggage"
            area = edge[2][5]
            node = edge[2][6]
            time = edge[2][4]
            area_node_time_flowin[area, node, time] = [area_node_time_flowin[area, node, time]; [serialized_edge]]
        end
    end

    # return a single dictionary for easier handling of outputs
    network_dictionary = Dict()
    network_dictionary["sources"] = serialized_sources
    network_dictionary["sinks"] = serialized_sinks
    network_dictionary["breaks"] = serialized_breaks
    network_dictionary["internal_vertices"] = serialized_internal
    network_dictionary["baggage"] = serialized_baggage
    network_dictionary["edges"] = unique(serialized_edges)
    network_dictionary["vertex_lookup_dict"] = vertex_lookup
    network_dictionary["id_lookup_dict"] = id_lookup
    network_dictionary["flow_in_dict"] = flow_in
    network_dictionary["flow_out_dict"] = flow_out
    network_dictionary["area_node_time_flowin_dict"] = area_node_time_flowin
    
    return network_dictionary
end

function construct_network_overtime_area(overtime_df, areas, traveling)
    vertices = DataFrame(type = String[], shiftid = Any[], overtimeid = Any[], t = Int[], area = Any[], node = Any[])
    edges = DataFrame(overtex = Array[], dvertex = Array[])
    serialized_baggage = []
    serialized_sources = []
    serialized_sinks = []
    serialized_internal = []
    serialized_edges = []
    vertex_lookup = Dict()
    id_lookup = Dict()
    flow_in = Dict()
    flow_out = Dict()
    area_node_time_flowin = Dict()
    id = 1
    for overtime_shift ∈ eachrow(overtime_df)
        shift_id = overtime_shift["Shift ID"]
        overtime_id = overtime_shift["Overtime ID"]
        ot_start = round(Int, overtime_shift["Start"])
        ot_end = round(Int, overtime_shift["End"])
        
        # create source vertex
        vertex = ["source", shift_id, overtime_id, ot_start, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sources, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_out dictionary for the source vertex
        flow_out[id] = []
        id += 1

        # create sink vertex
        vertex = ["sink", shift_id, overtime_id, ot_end, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sinks, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_in dictionary for the sink vertex
        flow_in[id] = []
        id += 1

        for t ∈ ot_start:(ot_end-1)
            # add baggage vertex
            baggage_area = length(keys(areas)) + 1
            vertex = ["baggage", shift_id, overtime_id, t, baggage_area, 1]
            push!(vertices, vertex)
            push!(serialized_baggage, id)
            vertex_lookup[id] = vertex
            id_lookup[vertex] = id
            flow_in[id] = []
            flow_out[id] = []
            id += 1
            area_node_time_flowin[baggage_area, 1, t] = []

            for area ∈ keys(areas)
                node = 1
                # instantiate area node time flowin dictionary
                area_node_time_flowin[area, node, t] = []

                # create internal vertex
                vertex = ["internal", shift_id, overtime_id, t, area, node]
                push!(vertices, vertex)
                # assign an id
                push!(serialized_internal, id)
                vertex_lookup[id] = vertex
                id_lookup[vertex] = id
                flow_in[id] = []
                flow_out[id] = []
                id += 1

                # add source edges
                if t == ot_start
                    push!(edges, [["source", shift_id, overtime_id, t, -1, -1],["internal", shift_id, overtime_id, t, area, node]])
                    if area == 1
                        push!(edges, [["source", shift_id, overtime_id, t, -1, -1],["baggage", shift_id, overtime_id, t, baggage_area, node]])
                    end 
                end

                # add internal edges
                for end_area ∈ keys(areas)
                    travel_end = t + traveling[[[area, node],[end_area, node]]]
                    if  travel_end < ot_end
                        push!(edges, [["internal", shift_id, overtime_id, t, area, node],["internal", shift_id, overtime_id, travel_end, end_area, node]])
                    end
                end

                # add baggage edges
                baggage_travel_end = t + 1
                if baggage_travel_end < ot_end
                    if area == 1
                        push!(edges, [["baggage", shift_id, overtime_id, t, baggage_area, node], ["baggage", shift_id, overtime_id, baggage_travel_end, baggage_area, node]])
                    end
                    push!(edges, [["internal", shift_id, overtime_id, t, area, node], ["baggage", shift_id, overtime_id, baggage_travel_end, baggage_area, node]])
                    push!(edges, [["baggage", shift_id, overtime_id, t, baggage_area, node], ["internal", shift_id, overtime_id, baggage_travel_end, area, node]])
                end

                # add sink edges
                if t == ot_end-1 
                    push!(edges, [["internal", shift_id, overtime_id, t, area, node],["sink", shift_id, overtime_id, t+1, -1, -1]])
                    if area == 1
                        push!(edges, [["baggage", shift_id, overtime_id, t, baggage_area, node],["sink", shift_id, overtime_id, t+1, -1, -1]])
                    end
                end
            end
        end
    end

    # rename the flow in to something that makes more sense, like preceding neighbors
    # do the same for flow out
    # to optimize, modify the construction loop and pace this in it
    for edge ∈ eachrow(edges)
        origin_id = id_lookup[edge[1]]
        destination_id = id_lookup[edge[2]]
        serialized_edge = [origin_id, destination_id]
        push!(serialized_edges, serialized_edge)
        # adds the origin to the list of nodes that the destination receives flow from
        flow_in[destination_id] = [flow_in[destination_id]; origin_id]
        # adds the destination to the list of nodes that the origin flows to
        flow_out[origin_id] = [flow_out[origin_id]; destination_id]
        # takes the current area node time dictionary and adds the origin that flow into it
        if edge[2][1] == "internal" || edge[2][1] == "baggage"
            area = edge[2][5]
            node = edge[2][6]
            time = edge[2][4]
            area_node_time_flowin[area, node, time] = [area_node_time_flowin[area, node, time]; [serialized_edge]]
        end
    end

    # return a single dictionary for easier handling of outputs
    network_dictionary = Dict()
    network_dictionary["sources"] = serialized_sources
    network_dictionary["sinks"] = serialized_sinks
    network_dictionary["internal_vertices"] = serialized_internal
    network_dictionary["baggage"] = serialized_baggage
    network_dictionary["edges"] = unique(serialized_edges)
    network_dictionary["vertex_lookup_dict"] = vertex_lookup
    network_dictionary["id_lookup_dict"] = id_lookup
    network_dictionary["flow_in_dict"] = flow_in
    network_dictionary["flow_out_dict"] = flow_out
    network_dictionary["area_node_time_flowin_dict"] = area_node_time_flowin
    
    return network_dictionary
end

function construct_network_breaks_area_movement_after_breaks(breaks_df, areas, traveling)
    vertices = DataFrame(type = String[], shiftid = Any[], breakid = Any[], t = Int[], area = Any[], node = Any[])
    edges = DataFrame(overtex = Array[], dvertex = Array[])
    serialized_baggage = []
    serialized_sources = []
    serialized_sinks = []
    serialized_breaks = []
    serialized_internal = []
    serialized_edges = []
    vertex_lookup = Dict()
    id_lookup = Dict()
    flow_in = Dict()
    flow_out = Dict()
    area_node_time_flowin = Dict()
    id = 1

    for break_schedule in eachrow(breaks_df)
        shift_id = break_schedule["Shift ID"]
        break_id = break_schedule["Break ID"]
        break_schedule_start = round(Int, break_schedule["Start"])
        break_schedule_end = round(Int, break_schedule["End"])
        
        # create source vertex
        vertex = ["source", shift_id, break_id, break_schedule_start, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sources, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_out dictionary for the source vertex
        flow_out[id] = []
        id += 1

        # create sink vertex
        vertex = ["sink", shift_id, break_id, break_schedule_end, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sinks, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_in dictionary for the sink vertex
        flow_in[id] = []
        id += 1

        if break_schedule["Breaks"] === missing
            breaks = []
        else
            breaks = break_schedule["Breaks"]
        end

        for t ∈ break_schedule_start:(break_schedule_end-1)
            current_period_is_break = t in breaks 
            next_period_is_break = (t + 1) in breaks

            # add baggage vertex
            baggage_area = length(keys(areas)) + 1
            vertex = ["baggage", shift_id, break_id, t, baggage_area, 1]
            push!(vertices, vertex)
            push!(serialized_baggage, id)
            vertex_lookup[id] = vertex
            id_lookup[vertex] = id
            flow_in[id] = []
            flow_out[id] = []
            id += 1
            area_node_time_flowin[baggage_area, 1, t] = []

            for area ∈ keys(areas)
                node = 1
                # instantiate area node time flowin dictionary
                area_node_time_flowin[area, node, t] = []
                # add internal vertices only when not in a break period
                if !current_period_is_break
                    vertex = ["internal", shift_id, break_id, t, area, node]
                    push!(vertices, vertex)
                    push!(serialized_internal, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1
                elseif current_period_is_break
                    vertex = ["break", shift_id, break_id, t, area, -1]
                    push!(vertices, vertex)
                    push!(serialized_breaks, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1

                    if area == 1
                        vertex = ["break", shift_id, break_id, t, baggage_area, -1]
                        push!(vertices, vertex)
                        push!(serialized_baggage, id)
                        vertex_lookup[id] = vertex
                        id_lookup[vertex] = id
                        flow_in[id] = []
                        flow_out[id] = []
                        id += 1
                    end
                end
                
                # add source edges, assumes no break at beginning of shift
                if t == break_schedule_start
                    push!(edges, [["source", shift_id, break_id, t, -1, -1],["internal", shift_id, break_id, t, area, node]])
                    if area == 1
                        push!(edges, [["source", shift_id, break_id, t, -1, -1],["baggage", shift_id, break_id, t, baggage_area, node]])
                    end 
                end

                # add sink edges, assumes no break at end of shift
                if t == break_schedule_end - 1
                    push!(edges, [["internal", shift_id, break_id, t, area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    if area == 1
                        push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    end
                end

                if current_period_is_break || next_period_is_break # add break edges if current or next period is a break
                    if !current_period_is_break && next_period_is_break # starting break next period
                        push!(edges, [["internal", shift_id, break_id, t, area, node], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    elseif current_period_is_break && !next_period_is_break # ending break this period
                        for end_area ∈ keys(areas)
                            travel_end = t + traveling[[[area, node],[end_area, node]]]
                            if travel_end < break_schedule_end
                                push!(edges, [["break", shift_id, break_id, t, area, -1], ["internal", shift_id, break_id, travel_end, end_area, node]])
                            end

                            if area == 1
                                travel_end = t + 1
                                if travel_end < break_schedule_end
                                    if end_area == 1
                                        push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["baggage", shift_id, break_id, travel_end, baggage_area, node]])
                                    end
                                    push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["internal", shift_id, break_id, travel_end, end_area, node]])
                                end
                            end
                        end
                    elseif current_period_is_break && next_period_is_break
                        push!(edges, [["break", shift_id, break_id, t, area, -1], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    end
                else # add normal edge otherwise, must be to the same area
                    travel_end = t + traveling[[[area, node],[area, node]]]
                    next_break_index = findfirst(breaks .> t)
                    if isnothing(next_break_index) # no more breaks left
                        if travel_end < break_schedule_end # travel isn't beyond shift
                            push!(edges, [["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, area, node]])
                        end
                    elseif travel_end < breaks[next_break_index] && travel_end < break_schedule_end # travel isn't to or beyond break and isn't beyond shift
                        push!(edges,[["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, area, node]])
                    end

                    # add baggage edges
                    baggage_travel_end = t + 1
                    next_break_index = findfirst(breaks .> t)
                    if isnothing(next_break_index) # no more breaks left
                        if baggage_travel_end < break_schedule_end
                            if area == 1
                                push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                            end
                        end
                    elseif baggage_travel_end < breaks[next_break_index] && baggage_travel_end < break_schedule_end
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                        end
                    end
                end
            end
        end
    end
    
    # rename the flow in to something that makes more sense, like preceding neighbors
    # do the same for flow out
    # to optimize, modify the construction loop and pace this in it
    for edge ∈ eachrow(edges)
        origin_id = id_lookup[edge[1]]
        destination_id = id_lookup[edge[2]]
        serialized_edge = [origin_id, destination_id]
        push!(serialized_edges, serialized_edge)
        # adds the origin to the list of nodes that the destination receives flow from
        flow_in[destination_id] = [flow_in[destination_id]; origin_id]
        # adds the destination to the list of nodes that the origin flows to
        flow_out[origin_id] = [flow_out[origin_id]; destination_id]
        # takes the current area node time dictionary and adds the origin that flow into it
        if edge[2][1] == "internal" || edge[2][1] == "baggage"
            area = edge[2][5]
            node = edge[2][6]
            time = edge[2][4]
            area_node_time_flowin[area, node, time] = [area_node_time_flowin[area, node, time]; [serialized_edge]]
        end
    end

    # return a single dictionary for easier handling of outputs
    network_dictionary = Dict()
    network_dictionary["sources"] = serialized_sources
    network_dictionary["sinks"] = serialized_sinks
    network_dictionary["breaks"] = serialized_breaks
    network_dictionary["internal_vertices"] = serialized_internal
    network_dictionary["baggage"] = serialized_baggage
    network_dictionary["edges"] = unique(serialized_edges)
    network_dictionary["vertex_lookup_dict"] = vertex_lookup
    network_dictionary["id_lookup_dict"] = id_lookup
    network_dictionary["flow_in_dict"] = flow_in
    network_dictionary["flow_out_dict"] = flow_out
    network_dictionary["area_node_time_flowin_dict"] = area_node_time_flowin
    
    return network_dictionary
end

function construct_network_breaks_area_no_movement(breaks_df, areas, traveling)
    vertices = DataFrame(type = String[], shiftid = Any[], breakid = Any[], t = Int[], area = Any[], node = Any[])
    edges = DataFrame(overtex = Array[], dvertex = Array[])
    serialized_baggage = []
    serialized_sources = []
    serialized_sinks = []
    serialized_breaks = []
    serialized_internal = []
    serialized_edges = []
    vertex_lookup = Dict()
    id_lookup = Dict()
    flow_in = Dict()
    flow_out = Dict()
    area_node_time_flowin = Dict()
    id = 1

    for break_schedule in eachrow(breaks_df)
        shift_id = break_schedule["Shift ID"]
        break_id = break_schedule["Break ID"]
        break_schedule_start = round(Int, break_schedule["Start"])
        break_schedule_end = round(Int, break_schedule["End"])
        
        # create source vertex
        vertex = ["source", shift_id, break_id, break_schedule_start, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sources, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_out dictionary for the source vertex
        flow_out[id] = []
        id += 1

        # create sink vertex
        vertex = ["sink", shift_id, break_id, break_schedule_end, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sinks, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_in dictionary for the sink vertex
        flow_in[id] = []
        id += 1

        if break_schedule["Breaks"] === missing
            breaks = []
        else
            breaks = break_schedule["Breaks"]
        end
        
        for t ∈ break_schedule_start:(break_schedule_end-1)
            current_period_is_break = t in breaks 
            next_period_is_break = (t + 1) in breaks

            # add baggage vertex
            baggage_area = length(keys(areas)) + 1
            vertex = ["baggage", shift_id, break_id, t, baggage_area, 1]
            push!(vertices, vertex)
            push!(serialized_baggage, id)
            vertex_lookup[id] = vertex
            id_lookup[vertex] = id
            flow_in[id] = []
            flow_out[id] = []
            id += 1
            area_node_time_flowin[baggage_area, 1, t] = []

            for area ∈ keys(areas)
                node = 1
                # instantiate area node time flowin dictionary
                area_node_time_flowin[area, node, t] = []
                # add internal vertices only when not in a break period
                if !current_period_is_break
                    vertex = ["internal", shift_id, break_id, t, area, node]
                    push!(vertices, vertex)
                    push!(serialized_internal, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1
                elseif current_period_is_break 
                    vertex = ["break", shift_id, break_id, t, area, -1]
                    push!(vertices, vertex)
                    push!(serialized_breaks, id)
                    vertex_lookup[id] = vertex
                    id_lookup[vertex] = id
                    # instantiate the flow_in and flow_out_dict
                    flow_in[id] = []
                    flow_out[id] = []
                    id += 1

                    if area == 1
                        vertex = ["break", shift_id, break_id, t, baggage_area, -1]
                        push!(vertices, vertex)
                        push!(serialized_baggage, id)
                        vertex_lookup[id] = vertex
                        id_lookup[vertex] = id
                        flow_in[id] = []
                        flow_out[id] = []
                        id += 1
                    end
                end
                
                # add source edges, assumes no break at beginning of shift
                if t == break_schedule_start
                    push!(edges, [["source", shift_id, break_id, t, -1, -1],["internal", shift_id, break_id, t, area, node]]) 
                    if area == 1
                        push!(edges, [["source", shift_id, break_id, t, -1, -1],["baggage", shift_id, break_id, t, baggage_area, node]])
                    end
                end

                # add sink edges, assumes no break at end of shift
                if t == break_schedule_end - 1
                    push!(edges, [["internal", shift_id, break_id, t, area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    if area == 1
                        push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node],["sink", shift_id, break_id, t+1, -1, -1]])
                    end
                end

                if current_period_is_break || next_period_is_break # add break edges if current or next period is a break
                    if !current_period_is_break && next_period_is_break 
                        push!(edges, [["internal", shift_id, break_id, t, area, node], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    elseif current_period_is_break && !next_period_is_break
                        push!(edges, [["break", shift_id, break_id, t, area, -1], ["internal", shift_id, break_id, t+1, area, node]])
                        if area == 1
                            push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["baggage", shift_id, break_id, t+1, baggage_area, node]])
                        end
                    elseif current_period_is_break && next_period_is_break
                        push!(edges, [["break", shift_id, break_id, t, area, -1], ["break", shift_id, break_id, t+1, area, -1]])
                        if area == 1
                            push!(edges, [["break", shift_id, break_id, t, baggage_area, -1], ["break", shift_id, break_id, t+1, baggage_area, -1]])
                        end
                    end
                else # add normal edges otherwise
                    travel_end = t + traveling[[[area, node],[area, node]]]
                    next_break_index = findfirst(breaks .> t)
                    if isnothing(next_break_index) # no more breaks left
                        if travel_end < break_schedule_end # travel isn't beyond shift
                            push!(edges, [["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, area, node]])
                        end
                    elseif travel_end < breaks[next_break_index] && travel_end < break_schedule_end # travel isn't to or beyond break and isn't beyond shift
                        push!(edges,[["internal", shift_id, break_id, t, area, node],["internal", shift_id, break_id, travel_end, area, node]])
                    end

                    baggage_travel_end = t + 1
                    next_break_index = findfirst(breaks .> t)
                    if isnothing(next_break_index) # no more breaks left
                        if baggage_travel_end < break_schedule_end
                            if area == 1
                                push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                            end
                        end
                    elseif baggage_travel_end < breaks[next_break_index] && baggage_travel_end < break_schedule_end
                        if area == 1
                            push!(edges, [["baggage", shift_id, break_id, t, baggage_area, node], ["baggage", shift_id, break_id, baggage_travel_end, baggage_area, node]])
                        end
                    end
                end
            end
        end
    end
    
    # rename the flow in to something that makes more sense, like preceding neighbors
    # do the same for flow out
    # to optimize, modify the construction loop and pace this in it
    for edge ∈ eachrow(edges)
        origin_id = id_lookup[edge[1]]
        destination_id = id_lookup[edge[2]]
        serialized_edge = [origin_id, destination_id]
        push!(serialized_edges, serialized_edge)
        # adds the origin to the list of nodes that the destination receives flow from
        flow_in[destination_id] = [flow_in[destination_id]; origin_id]
        # adds the destination to the list of nodes that the origin flows to
        flow_out[origin_id] = [flow_out[origin_id]; destination_id]
        # takes the current area node time dictionary and adds the origin that flow into it
        if edge[2][1] == "internal" || edge[2][1] == "baggage"
            area = edge[2][5]
            node = edge[2][6]
            time = edge[2][4]
            area_node_time_flowin[area, node, time] = [area_node_time_flowin[area, node, time]; [serialized_edge]]
        end
    end

    # return a single dictionary for easier handling of outputs
    network_dictionary = Dict()
    network_dictionary["sources"] = serialized_sources
    network_dictionary["sinks"] = serialized_sinks
    network_dictionary["breaks"] = serialized_breaks
    network_dictionary["internal_vertices"] = serialized_internal
    network_dictionary["edges"] = unique(serialized_edges)
    network_dictionary["baggage"] = serialized_baggage
    network_dictionary["vertex_lookup_dict"] = vertex_lookup
    network_dictionary["id_lookup_dict"] = id_lookup
    network_dictionary["flow_in_dict"] = flow_in
    network_dictionary["flow_out_dict"] = flow_out
    network_dictionary["area_node_time_flowin_dict"] = area_node_time_flowin
    
    return network_dictionary
end

function construct_network_overtime_area_no_movement(overtime_df, areas, traveling)
    vertices = DataFrame(type = String[], shiftid = Any[], overtimeid = Any[], t = Int[], area = Any[], node = Any[])
    edges = DataFrame(overtex = Array[], dvertex = Array[])
    serialized_baggage = []
    serialized_sources = []
    serialized_sinks = []
    serialized_internal = []
    serialized_edges = []
    vertex_lookup = Dict()
    id_lookup = Dict()
    flow_in = Dict()
    flow_out = Dict()
    area_node_time_flowin = Dict()
    id = 1

    for overtime_shift ∈ eachrow(overtime_df)
        shift_id = overtime_shift["Shift ID"]
        overtimeid = overtime_shift["Overtime ID"]
        ot_start = round(Int, overtime_shift["Start"])
        ot_end = round(Int, overtime_shift["End"])
        
        # create source vertex
        vertex = ["source", shift_id, overtimeid, ot_start, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sources, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_out dictionary for the source vertex
        flow_out[id] = []
        id += 1

        # create sink vertex
        vertex = ["sink", shift_id, overtimeid, ot_end, -1, -1]
        push!(vertices, vertex)
        # assign an id to the vertex
        push!(serialized_sinks, id)
        vertex_lookup[id] = vertex
        id_lookup[vertex] = id
        # instantiate the flow_in dictionary for the sink vertex
        flow_in[id] = []
        id += 1

        for t ∈ ot_start:(ot_end-1)
            # add baggage vertex
            baggage_area = length(keys(areas)) + 1
            vertex = ["baggage", shift_id, overtimeid, t, baggage_area, 1]
            push!(vertices, vertex)
            push!(serialized_baggage, id)
            vertex_lookup[id] = vertex
            id_lookup[vertex] = id
            flow_in[id] = []
            flow_out[id] = []
            id += 1
            area_node_time_flowin[baggage_area, 1, t] = []

            for area ∈ keys(areas)
                node = 1
                # instantiate area node time flowin dictionary
                area_node_time_flowin[area, node, t] = []

                # create internal vertex
                vertex = ["internal", shift_id, overtimeid, t, area, node]
                push!(vertices, vertex)
                # assign an id
                push!(serialized_internal, id)
                vertex_lookup[id] = vertex
                id_lookup[vertex] = id
                flow_in[id] = []
                flow_out[id] = []
                id += 1

                # add source edges
                if t == ot_start
                    push!(edges, [["source", shift_id, overtimeid, t, -1, -1],["internal", shift_id, overtimeid, t, area, node]]) 
                    if area == 1
                        push!(edges, [["source", shift_id, overtimeid, t, -1, -1],["baggage", shift_id, overtimeid, t, baggage_area, node]])
                    end
                end

                # add internal edges
                travel_end = t + traveling[[[area, node],[area, node]]]
                if  travel_end < ot_end
                    push!(edges, [["internal", shift_id, overtimeid, t, area, node],["internal", shift_id, overtimeid, travel_end, area, node]])
                    if area == 1
                        baggage_travel_end = t+1
                        push!(edges, [["baggage", shift_id, overtimeid, t, baggage_area, node], ["baggage", shift_id, overtimeid, baggage_travel_end, baggage_area, node]])
                    end
                end

                # add sink edges
                if t == ot_end - 1
                    push!(edges, [["internal", shift_id, overtimeid, t, area, node],["sink", shift_id, overtimeid, t+1, -1, -1]])
                    if area == 1
                        push!(edges, [["baggage", shift_id, overtimeid, t, baggage_area, node],["sink", shift_id, overtimeid, t+1, -1, -1]])
                    end
                end
            end
        end
    end

    # rename the flow in to something that makes more sense, like preceding neighbors
    # do the same for flow out
    # to optimize, modify the construction loop and pace this in it
    for edge ∈ eachrow(edges)
        origin_id = id_lookup[edge[1]]
        destination_id = id_lookup[edge[2]]
        serialized_edge = [origin_id, destination_id]
        push!(serialized_edges, serialized_edge)
        # adds the origin to the list of nodes that the destination receives flow from
        flow_in[destination_id] = [flow_in[destination_id]; origin_id]
        # adds the destination to the list of nodes that the origin flows to
        flow_out[origin_id] = [flow_out[origin_id]; destination_id]
        # takes the current area node time dictionary and adds the origin that flow into it
        if edge[2][1] == "internal" || edge[2][1] == "baggage"
            area = edge[2][5]
            node = edge[2][6]
            time = edge[2][4]
            area_node_time_flowin[area, node, time] = [area_node_time_flowin[area, node, time]; [serialized_edge]]
        end
    end

    # return a single dictionary for easier handling of outputs
    network_dictionary = Dict()
    network_dictionary["sources"] = serialized_sources
    network_dictionary["sinks"] = serialized_sinks
    network_dictionary["internal_vertices"] = serialized_internal
    network_dictionary["baggage"] = serialized_baggage
    network_dictionary["edges"] = unique(serialized_edges)
    network_dictionary["vertex_lookup_dict"] = vertex_lookup
    network_dictionary["id_lookup_dict"] = id_lookup
    network_dictionary["flow_in_dict"] = flow_in
    network_dictionary["flow_out_dict"] = flow_out
    network_dictionary["area_node_time_flowin_dict"] = area_node_time_flowin
    
    return network_dictionary
end

function write_network_area(vertex_lookup_dict, output)
    if !isfile(output)
        ids = collect(keys(vertex_lookup_dict))
        shift_ids = []
        break_ids = []
        time_periods = []
        locations = []
        for id in ids
            push!(shift_ids, vertex_lookup_dict[id][2])
            push!(break_ids, vertex_lookup_dict[id][3])
            push!(time_periods, vertex_lookup_dict[id][4])
            location = [vertex_lookup_dict[id][5], vertex_lookup_dict[id][6]]
            if vertex_lookup_dict[id][1] == "baggage"
                push!(locations, "Bag")
            elseif location[2] == -1
                push!(locations, "Off")
            else
                push!(locations, "Ckpt $(location[1])")
            end
        end
    
        CSV.write(output, DataFrame(id = ids, shift_id = shift_ids, break_id = break_ids, time_period = time_periods, location = locations))
        println("successfully wrote network $output")
    else
        @warn("File already exists nothing happened.")
    end
end

function write_network_area_with_source_and_sink(vertex_lookup_dict, output)
    if !isfile(output)
        ids = collect(keys(vertex_lookup_dict))
        shift_ids = []
        break_ids = []
        time_periods = []
        locations = []
        for id in ids
            push!(shift_ids, vertex_lookup_dict[id][2])
            push!(break_ids, vertex_lookup_dict[id][3])
            push!(time_periods, vertex_lookup_dict[id][4])
            location = [vertex_lookup_dict[id][5], vertex_lookup_dict[id][6]]
            if vertex_lookup_dict[id][1] == "baggage"
                push!(locations, "Bag")
            elseif location[2] == -1
                push!(locations, vertex_lookup_dict[id][1])
            else
                push!(locations, "Ckpt $(location[1])")
            end
        end
    
        CSV.write(output, DataFrame(id = ids, shift_id = shift_ids, break_id = break_ids, time_period = time_periods, location = locations))
        println("successfully wrote network $output")
    else
        @warn("File already exists nothing happened.")
    end
end

function create_network_lookup_df(vertex_lookup_dict)
    ids = collect(keys(vertex_lookup_dict))
    shift_ids = []
    break_ids = []
    time_periods = []
    locations = []
    for id in ids
        push!(shift_ids, vertex_lookup_dict[id][2])
        push!(break_ids, vertex_lookup_dict[id][3])
        push!(time_periods, vertex_lookup_dict[id][4])
        location = [vertex_lookup_dict[id][5], vertex_lookup_dict[id][6]]
        if location == [-1, -1]
            push!(locations, "Off Duty")
        elseif location[2] == 1
            push!(locations, "Ckpt $(location[1])")
        end
    end

    network_lookup_df = DataFrame(id = ids, shift_id = shift_ids, break_id = break_ids, time_period = time_periods, location = locations)

    return network_lookup_df
end

function flow_lookup_df_to_dict(network_lookup_df)
    vertex_lookup_dict = Dict()
    for row ∈ eachrow(network_lookup_df)
        vertex_lookup_dict[row.id] = [row.shift_id, row.break_id, row.time_period, row.location]
    end
    return vertex_lookup_dict
end
