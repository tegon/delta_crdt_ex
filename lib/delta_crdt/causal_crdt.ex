defmodule DeltaCrdt.CausalCrdt do
  use GenServer

  require Logger

  @default_ship_interval 50
  @default_ship_debounce 50

  @ship_after_x_deltas 1000
  @gc_interval 10_000

  @type delta :: {k :: integer(), delta :: any()}
  @type delta_interval :: {a :: integer(), b :: integer(), delta :: delta()}

  @moduledoc """
  DeltaCrdt implements Algorithm 2 from `Delta State Replicated Data Types – Almeida et al. 2016`
  which is an anti-entropy algorithm for δ-CRDTs. You can find the original paper here: https://arxiv.org/pdf/1603.01529.pdf
  """

  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, nil)
    crdt_module = Keyword.get(opts, :crdt, nil)
    notify = Keyword.get(opts, :notify, nil)
    ship_interval = Keyword.get(opts, :ship_interval, @default_ship_interval)
    ship_debounce = Keyword.get(opts, :ship_debounce, @default_ship_debounce)

    if is_nil(name) do
      raise "must specify :name in options, got: #{inspect(opts)}"
    end

    if is_nil(crdt_module) do
      raise "must specify :crdt in options, got: #{inspect(opts)}"
    end

    %{
      id: name,
      start:
        {__MODULE__, :start_link,
         [crdt_module, notify, ship_interval, ship_debounce, [name: name]]}
    }
  end

  @doc """
  Start a DeltaCrdt.
  """
  def start_link(
        crdt_module,
        notify \\ nil,
        ship_interval \\ @default_ship_interval,
        ship_debounce \\ @default_ship_debounce,
        opts \\ []
      ) do
    GenServer.start_link(__MODULE__, {crdt_module, notify, ship_interval, ship_debounce}, opts)
  end

  def read(server, timeout \\ 5000) do
    {crdt_module, state} = GenServer.call(server, :read)
    apply(crdt_module, :read, [state])
  end

  defmodule State do
    defstruct node_id: nil,
              notify: nil,
              neighbours: MapSet.new(),
              crdt_module: nil,
              crdt_state: nil,
              shipped_sequence_number: 0,
              sequence_number: 0,
              ship_debounce: 0,
              deltas: %{},
              ack_map: %{}
  end

  def init({crdt_module, notify, ship_interval, ship_debounce}) do
    DeltaCrdt.Periodic.start_link(:garbage_collect_deltas, @gc_interval)
    DeltaCrdt.Periodic.start_link(:try_ship, ship_interval)

    Process.flag(:trap_exit, true)

    {:ok,
     %State{
       node_id: :rand.uniform(1_000_000_000),
       notify: notify,
       crdt_module: crdt_module,
       ship_debounce: ship_debounce,
       crdt_state: crdt_module.new()
     }}
  end

  def terminate(_reason, state) do
    ship_interval_or_state_to_all(state)
  end

  defp send_notification(%{notify: nil}), do: nil

  defp send_notification(%{notify: {pid, msg}}) do
    case Process.whereis(pid) do
      nil -> nil
      loc -> send(loc, msg)
    end
  end

  defp ship_state_to_neighbour(neighbour, state) do
    remote_acked = Map.get(state.ack_map, neighbour, 0)

    if Enum.empty?(state.deltas) || Map.keys(state.deltas) |> Enum.min() > remote_acked do
      send(neighbour, {:delta, {self(), state.crdt_state}, state.sequence_number})
    else
      state.deltas
      |> Enum.filter(fn
        {_i, {^neighbour, _delta}} -> false
        _ -> true
      end)
      |> Enum.filter(fn {i, _delta} -> remote_acked <= i && i < state.sequence_number end)
      |> case do
        [] ->
          nil

        deltas ->
          delta_interval =
            Enum.map(deltas, fn {_i, {_from, delta}} -> delta end)
            |> Enum.reduce(fn delta, delta_interval ->
              DeltaCrdt.SemiLattice.join(delta_interval, delta)
            end)

          if(remote_acked < state.sequence_number) do
            send(neighbour, {:delta, {self(), delta_interval}, state.sequence_number})
          end
      end
    end
  end

  defp ship_interval_or_state_to_all(state) do
    Enum.each(state.neighbours, fn n -> ship_state_to_neighbour(n, state) end)
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(:ship_interval_or_state_to_all, state) do
    ship_interval_or_state_to_all(state)

    {:noreply, state}
  end

  def handle_call(:garbage_collect_deltas, _from, state) do
    if Enum.empty?(state.neighbours) do
      {:noreply, state}
    else
      l =
        state.neighbours
        |> Enum.filter(fn neighbour -> Map.has_key?(state.ack_map, neighbour) end)
        |> Enum.map(fn neighbour -> Map.get(state.ack_map, neighbour, 0) end)
        |> Enum.min(fn -> 0 end)

      new_deltas = state.deltas |> Enum.filter(fn {i, _delta} -> i >= l end) |> Map.new()
      {:reply, :ok, %{state | deltas: new_deltas}}
    end
  end

  def handle_info({:add_neighbours, pids}, state) do
    new_neighbours = pids |> MapSet.new() |> MapSet.union(state.neighbours)

    {:noreply, %{state | neighbours: new_neighbours}}
  end

  def handle_info({:add_neighbour, neighbour_pid}, state) do
    new_neighbours = MapSet.put(state.neighbours, neighbour_pid)
    {:noreply, %{state | neighbours: new_neighbours}}
  end

  def handle_info(
        {:delta, {neighbour, %{state: _d_s, causal_context: delta_c} = delta_interval}, n},
        %{crdt_state: %{state: _s, causal_context: c}} = state
      ) do
    last_known_states = c.maxima

    first_new_states =
      Enum.reduce(delta_c.dots, %{}, fn {n, v}, acc ->
        Map.update(acc, n, v, fn y -> Enum.min([v, y]) end)
      end)

    reject =
      first_new_states
      |> Enum.find(false, fn {n, v} ->
        case Map.get(last_known_states, n) do
          nil -> false
          x -> x + 1 < v
        end
      end)

    if reject do
      Logger.debug(fn ->
        "not applying delta interval from #{inspect(neighbour)} because #{
          inspect(last_known_states)
        } is incompatible with #{inspect(first_new_states)}"
      end)

      {:noreply, state}
    else
      new_crdt_state =
        DeltaCrdt.SemiLattice.join(state.crdt_state, delta_interval)
        |> DeltaCrdt.SemiLattice.compress()

      new_deltas = Map.put(state.deltas, state.sequence_number, {neighbour, delta_interval})
      new_sequence_number = state.sequence_number + 1

      new_state = %{
        state
        | crdt_state: new_crdt_state,
          deltas: new_deltas,
          sequence_number: new_sequence_number
      }

      send(neighbour, {:ack, self(), n})
      {:noreply, new_state}
    end
  end

  def handle_info({:ack, neighbour, n}, state) do
    if(Map.get(state.ack_map, neighbour, 0) >= n) do
      {:noreply, state}
    else
      new_ack_map = Map.put(state.ack_map, neighbour, n)
      {:noreply, %{state | ack_map: new_ack_map}}
    end
  end

  def handle_call(:try_ship, _f, %{shipped_sequence_number: same, sequence_number: same} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:try_ship, _f, state) do
    Process.send_after(self(), {:ship, state.sequence_number}, state.ship_debounce)
    {:reply, :ok, state}
  end

  def handle_info({:ship, s}, %{shipped_sequence_number: old_s} = state)
      when s > old_s + @ship_after_x_deltas do
    ship_interval_or_state_to_all(state)

    send_notification(state)

    {:noreply, %{state | shipped_sequence_number: s}}
  end

  def handle_info({:ship, s}, %{sequence_number: s} = state) do
    ship_interval_or_state_to_all(state)

    send_notification(state)

    {:noreply, %{state | shipped_sequence_number: s}}
  end

  def handle_info({:ship, s}, state) do
    {:noreply, state}
  end

  def handle_call(:read, _from, %{crdt_module: crdt_module, crdt_state: crdt_state} = state),
    do: {:reply, {crdt_module, crdt_state}, state}

  def handle_call({:read, module}, _from, state) do
    ret = apply(module, :read, [state.crdt_state])
    {:reply, ret, state}
  end

  def handle_call({:operation, operation}, _from, state) do
    {:reply, :ok, handle_operation(operation, state)}
  end

  def handle_cast({:operation, operation}, state) do
    {:noreply, handle_operation(operation, state)}
  end

  def handle_operation({function, args}, state) do
    delta = apply(state.crdt_module, function, args ++ [state.node_id, state.crdt_state])

    new_crdt_state =
      DeltaCrdt.SemiLattice.join(state.crdt_state, delta)
      |> DeltaCrdt.SemiLattice.compress()

    new_deltas = Map.put(state.deltas, state.sequence_number, {self(), delta})

    new_sequence_number = state.sequence_number + 1

    Map.put(state, :deltas, new_deltas)
    |> Map.put(:crdt_state, new_crdt_state)
    |> Map.put(:sequence_number, new_sequence_number)
  end
end

defmodule DeltaCrdt.Periodic do
  use GenServer

  def start_link(message, interval) do
    parent = self()
    GenServer.start_link(__MODULE__, {parent, message, interval})
  end

  def init({parent, message, interval}) do
    Process.send_after(self(), :tick, interval)
    {:ok, {parent, message, interval}}
  end

  def handle_info(:tick, {parent, message, interval}) do
    GenServer.call(parent, message, :infinity)
    Process.send_after(self(), :tick, interval)
    {:noreply, {parent, message, interval}}
  end
end
