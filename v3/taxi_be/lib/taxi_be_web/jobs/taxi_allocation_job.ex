defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  @eta_minutes 5
  # Penalty threshold: cancel is free if taxi is more than 3 min away
  @penalty_threshold_minutes 3

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request}}
  end

  # Select 3 candidates, broadcast the ride request to all 3 simultaneously,
  # and start a single 90-second timer.
  def handle_info(:step1, %{request: request}) do
    candidates = Enum.take(Enum.shuffle(candidate_taxis()), 3)

    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    Enum.each(candidates, fn taxi ->
      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> taxi.nickname,
        "booking_request",
        %{
          msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
          bookingId: booking_id
        }
      )
    end)

    timer_ref = Process.send_after(self(), :timeout, 90_000)

    {:noreply, %{
      request: request,
      contacted_taxis: Enum.map(candidates, & &1.nickname) |> MapSet.new(),
      rejected_drivers: MapSet.new(),
      timer_ref: timer_ref,
      phase: :awaiting_acceptance,
      accepted_driver: nil,
      arrives_at: nil,
      active: true
    }}
  end

  # First driver to accept wins. Cancel timer, notify customer, move to
  # awaiting_arrival phase. Any later acceptances are ignored.
  def handle_cast({:process_accept, driver_username}, state) do
    if state.active and state.phase == :awaiting_acceptance and
         MapSet.member?(state.contacted_taxis, driver_username) do
      Process.cancel_timer(state.timer_ref)
      customer_username = state.request["username"]

      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> customer_username,
        "booking_request",
        %{msg: "Tu taxi (#{driver_username}) está en camino. Tiempo estimado: #{@eta_minutes} minutos."}
      )

      # Arrival timer: when this fires the taxi has arrived and the trip starts
      arrival_timer_ref = Process.send_after(self(), :taxi_arrived, @eta_minutes * 60_000)

      {:noreply, %{state |
        phase: :awaiting_arrival,
        accepted_driver: driver_username,
        arrives_at: System.monotonic_time(:second) + @eta_minutes * 60,
        timer_ref: arrival_timer_ref
      }}
    else
      {:noreply, state}
    end
  end

  # Count rejections only once per driver. Only matters while awaiting_acceptance.
  # If all contacted drivers have rejected, notify customer and close.
  def handle_cast({:process_reject, driver_username}, state) do
    IO.inspect("'#{driver_username}' is rejecting a booking request")

    if state.active and state.phase == :awaiting_acceptance and
         MapSet.member?(state.contacted_taxis, driver_username) and
         not MapSet.member?(state.rejected_drivers, driver_username) do
      new_rejected_drivers = MapSet.put(state.rejected_drivers, driver_username)

      if MapSet.size(new_rejected_drivers) >= MapSet.size(state.contacted_taxis) do
        Process.cancel_timer(state.timer_ref)
        notify_no_taxi(state.request["username"])
        {:noreply, %{state | rejected_drivers: new_rejected_drivers, active: false}}
      else
        {:noreply, %{state | rejected_drivers: new_rejected_drivers}}
      end
    else
      {:noreply, state}
    end
  end

  # Customer cancels the booking.
  def handle_cast({:process_cancel, _customer_username}, state) do
    if not state.active do
      {:noreply, state}
    else
      Process.cancel_timer(state.timer_ref)
      customer_username = state.request["username"]

      case state.phase do
        :awaiting_acceptance ->
          # No driver has accepted yet — cancel with no penalty
          TaxiBeWeb.Endpoint.broadcast(
            "customer:" <> customer_username,
            "booking_request",
            %{msg: "Reservación cancelada sin penalización."}
          )
          {:noreply, %{state | active: false}}

        :awaiting_arrival ->
          # Compute how many minutes remain until the taxi arrives.
          remaining_seconds = max(state.arrives_at - System.monotonic_time(:second), 0)
          remaining_minutes = remaining_seconds / 60

          if remaining_minutes > @penalty_threshold_minutes do
            TaxiBeWeb.Endpoint.broadcast(
              "customer:" <> customer_username,
              "booking_request",
              %{msg: "Reservación cancelada sin penalización. El taxi aún está a más de #{@penalty_threshold_minutes} minutos."}
            )
          else
            TaxiBeWeb.Endpoint.broadcast(
              "customer:" <> customer_username,
              "booking_request",
              %{msg: "Reservación cancelada con penalización de $20. El taxi estaba a #{Float.round(remaining_minutes, 1)} minuto(s) de distancia."}
            )
          end
          {:noreply, %{state | active: false}}
      end
    end
  end

  # No driver accepted within 1.5 minutes.
  def handle_info(:timeout, state) do
    if state.active do
      notify_no_taxi(state.request["username"])
      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  # Taxi has arrived — trip starts normally. Close the booking.
  def handle_info(:taxi_arrived, state) do
    if state.active do
      customer_username = state.request["username"]

      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> customer_username,
        "booking_request",
        %{msg: "Tu taxi (#{state.accepted_driver}) ha llegado. ¡Buen viaje!"}
      )

      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  defp notify_no_taxi(customer_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer_username,
      "booking_request",
      %{msg: "Lo sentimos, no fue posible asignarte un taxi en este momento."}
    )
  end

  def candidate_taxis() do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "pippin", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end
end
