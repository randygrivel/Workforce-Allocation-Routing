# Overview

The code and data contained in this repository gives you the models that were used to create the tests for the models contained in the paper titled `A Workforce Allocation and Scheduling Model for Sequential Service Systems with Disjoint Service Areas and Resource Sharing`. This read me along with the paper should give you the information you need to start exploring the models created. You should reference section 3 of the paper for an understanding of the mathematical construction and assumption of the model and section 4 for the specific assumptions for the use by the TSA. The data provided in this repository is for a 3 checkpoint model based off of data from PHX airport so there will be some discrepencies based off of that.

# How to install

1. Install Julia using the downloads page https://julialang.org/downloads/.
2. Install solver of your choice (e.g. Gurobi or CPLEX).
3. In the command line run the command `julia`.
4. Install all packages in julia either using `Pkg.add("package_name")` or going into the package manager mode by pressing the `]` key and then using `add package_name`.
    Packages to add:
        - CPLEX (or whichever solver you are using)
        - JuMP 
        - XLSX
        - DataFrames
        - CSV
        - Distributions

If you have trouble getting the code to run send me an email at `rgrivel@asu.edu` and I will clarify any additional steps needed. 

# Code Relationships Explained

Three julia files are used to process input data and create a model to run. The first is the `DataProcessing.jl` file, this is used to store all the data in several variables that will be used for other tasks.

This data can then be used in the `NetworkConstruction.jl` file to create the appropriate time expanded network. This network currently only supports movements between different Areas (SSCPs) and doesn't account for movement between nodes (TDCs and SLs).

With the rest of the data processed it can be used with the functions in `ModelConstruction.jl` to create a model to optimize. The file `Model Number Notes.xlsx` contains notes on which model type has which features.

You can use `test_run.jl` to test the model using the data in `test_input.xlsx`. I have created a function, `read_data_and_solve_model()` that shows a lot of the different options that can be used when modifying the aspects of the airport security behavior that can be modeled without changing the actual design of the airport. You can also swap the solver from CPLEX to Gurobi or SCIP or any other solver that is compatible with the Julia JuMP packages. 


# Input Data Explained
Most changeable parameters are included in the `test_input.xlsx` file this allows you to make changes to the way the airport is structured.

## Sheet : Service Areas

- Each row describes a unique checkpoint (referred to as a `Service Area`).
- The `Service Nodes` column refers to the steps of processing a passenger must go through before leaving (e.g. in general, this is 2, TDC and SL).
- `Max Stations` refers to the maximum number of stations for each step of processing, in `test_input.xlsx` the `C2` shows 7,14 for 7 possible TDCs open and 14 for 14 possible SLs open. 
- The next two columns `Station Rate` and `Station Resources` define all the processing rates and total resources required for each processing step. This must be the same size as the sum of all `Max Stations`, so for the first row of `test_input.xlsx` you will see the first 7 numbers corresponding to the rate and resources of the TDCs and the next 14 number corresponding to the rate and resources of the SLs respectively.
- The `Buffer Capacity` is the maximum number of passengers that can be in a queue at the end of a period times the number of stations open at a service node. For the test data, the SLs have a capacity of 25 * number of SLs open.
- `Open` gives the beginning of the first period that the area can be open and `Close` give the beginning of the period that the area must be closed (if there are 96 periods in a day closing in period 97 means you close at the end of period 96).

## Sheet : Baggage

It is assumed the demand for baggage is calculated offline and the staffing needs are known before running the model. This can also be treated as a seperate service area with different arrivals with some additional reworking of the input and model creation.

## Sheet : Certification Requirements

For each area node combination, give the number of certified workers required to each configuration, if there are 7 possible configurations you need 7 different numbers for each column.

## Sheet : Shifts

- `Shift ID` is an arbitrary id given - must match the id in `Breaks` and `Overtime` sheets
- `Hired` gives the number of TSOs hired for a shift
- `Cert X` is a boolean of whether or not a TSO on the shift has certification `X`
- `Start` and `End` define the start and end of a shift (TSOs work up to the end of the shift e.g. if a shift ends at the end of a 96 period day then they end their shift period 97)

## Sheet : Breaks

This sheet defines which different break options are available for each shift, the column `Breaks` gives the periods breaks are taken for a given option and all TSOs `Hired` on a a shift (from the Shifts sheet) must be allocated to these break options.

## Sheet : Overtime

All overtime options for a shift, the maximum number of TSOs available for an overtime shift can be limited.

## Sheet : Parameters

- time_periods is the planning horizon
- num_scenarios is for future use for a stochastic model, use 1
- M is the number of periods a configuration must remain open after being chosen
- scenario weights is for future use for a stochastic model, use 1
- cost_regularization can be used to regularize the waiting cost and configuration costs, read the note in the sheet to adjust this.
- fraction_shift_OT is the fraction of TSOs on a shift that are available to work overtime 1 = 100% available
- per_period_per_config_cost is to adjust the configuration cost
- ramp_penalty is the fraction of a period a node loses productivity as it is opening or closing

## Sheet : Walking

This sheet defines the time to walk from any area (SSCP) and node (TDC/SL) to any other area and node. Currently the model ignores travel between nodes (TDC/SL) and only to different areas (SSCP). If travel is symmetric this can eventally be replaced with a matrix.