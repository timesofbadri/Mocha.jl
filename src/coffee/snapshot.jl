using HDF5, JLD

export Snapshot

type Snapshot <: Coffee
  dir :: String
  auto_load :: Bool
  also_load_solver_state :: Bool

  Snapshot(dir; auto_load=true, also_load_solver_state=true) = 
      new(dir, auto_load, also_load_solver_state)
end

function init(coffee::Snapshot, ::Net)
  if isdir(coffee.dir)
    @info("Snapshot directory $(coffee.dir) already exists")
  else
    @info("Snapshot directory $(coffee.dir) does not exist, creating...")
    mkdir_p(coffee.dir)
  end
end

const SOLVER_STATE_KEY = "solver_state"

function enjoy(coffee::Snapshot, ::CoffeeBreakTime.Morning, net::Net, state::SolverState)
  if state.iter == 0 && coffee.auto_load
    # try to auto load
    snapshots = glob(coffee.dir, r"^snapshot-[0-9]+\.jld$", sort_by=:mtime)
    if length(snapshots) > 0
      snapshot = snapshots[end]
      @info("Auto-loading from the latest snapshot $snapshot...")
      jldopen(joinpath(coffee.dir, snapshot)) do file
        load_network(file, net)
        if coffee.also_load_solver_state
          saved_state = read(file, SOLVER_STATE_KEY)
          copy_solver_state!(state, saved_state)
        end
      end
    end
  end
end

function enjoy(coffee::Snapshot, ::CoffeeBreakTime.Evening, net::Net, state::SolverState)
  fn = @sprintf("snapshot-%06d.jld", state.iter)
  @info("Saving snapshot to $fn...")
  path = joinpath(coffee.dir, fn)
  if isfile(path)
    @warn("Overwriting $path...")
  end

  jldopen(path, "w") do file
    save_network(file, net)
    write(file, SOLVER_STATE_KEY, state)
  end
end
