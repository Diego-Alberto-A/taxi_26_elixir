defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

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
      rejected_count: 0,
      timer_ref: timer_ref,
      active: true
    }}
  end

  # First driver to accept wins. Cancel timer, notify customer, close booking.
  # Any later acceptances are ignored because active will be false.
  def handle_cast({:process_accept, driver_username}, state) do
    if state.active and MapSet.member?(state.contacted_taxis, driver_username) do
      Process.cancel_timer(state.timer_ref)
      customer_username = state.request["username"]
      eta_minutes = 1

      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> customer_username,
        "booking_request",
        %{msg: "Tu taxi (#{driver_username}) está en camino. Tiempo estimado: #{eta_minutes} minutos."}
      )

      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  # Count rejections. Only matters while booking is still active.
  # If all 3 contacted drivers have rejected, notify customer and close.
  def handle_cast({:process_reject, driver_username}, state) do
    IO.inspect("'#{driver_username}' is rejecting a booking request")

    if state.active and MapSet.member?(state.contacted_taxis, driver_username) do
      new_rejected = state.rejected_count + 1

      if new_rejected >= MapSet.size(state.contacted_taxis) do
        Process.cancel_timer(state.timer_ref)
        notify_no_taxi(state.request["username"])
        {:noreply, %{state | rejected_count: new_rejected, active: false}}
      else
        {:noreply, %{state | rejected_count: new_rejected}}
      end
    else
      {:noreply, state}
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
