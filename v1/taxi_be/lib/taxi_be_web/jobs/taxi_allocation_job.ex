defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request}}
  end

  def handle_info(:step1, %{request: request}) do
    task = Task.async(fn -> Enum.random(candidate_taxis()) end)

    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    taxi = Task.await(task)

    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
      %{
        msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
        bookingId: booking_id
      }
    )

    timer_ref = Process.send_after(self(), :timeout, 5000)
    {:noreply, %{
      request: request,
      contacted_taxi: taxi,
      remaining_candidates: candidate_taxis() -- [taxi],
      failed_attempts: 0,
      timer_ref: timer_ref,
      active: true
    }}
  end

  # El taxista aceptó: solo se procesa si el proceso sigue activo y es el conductor
  # actualmente contactado. Ignora respuestas tardías de conductores anteriores o
  # del último conductor si el proceso ya cerró por fallos.
  def handle_cast({:process_accept, driver_username}, state) do
    if state.active and driver_username == state.contacted_taxi.nickname do
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

  # El taxista rechazó: cancelar el timer e intentar con el siguiente
  def handle_cast({:process_reject, driver_username}, state) do
    IO.inspect("'#{driver_username}' is rejecting a booking request")
    Process.cancel_timer(state.timer_ref)
    try_next_taxi(state)
  end

  # Pasó 1 minuto sin respuesta: eliminar taxista e intentar con el siguiente
  def handle_info(:timeout, state) do
    try_next_taxi(state)
  end

  defp try_next_taxi(state) do
    new_failed = state.failed_attempts + 1
    customer_username = state.request["username"]

    cond do
      new_failed >= 3 ->
        TaxiBeWeb.Endpoint.broadcast(
          "customer:" <> customer_username,
          "booking_request",
          %{msg: "Lo sentimos, no fue posible asignarte un taxi en este momento."}
        )
        {:noreply, %{state | failed_attempts: new_failed, active: false}}

      state.remaining_candidates == [] ->
        TaxiBeWeb.Endpoint.broadcast(
          "customer:" <> customer_username,
          "booking_request",
          %{msg: "Lo sentimos, no hay taxistas disponibles en este momento."}
        )
        {:noreply, %{state | failed_attempts: new_failed, active: false}}

      true ->
        [next_taxi | rest] = state.remaining_candidates

        %{
          "pickup_address" => pickup_address,
          "dropoff_address" => dropoff_address,
          "booking_id" => booking_id
        } = state.request

        TaxiBeWeb.Endpoint.broadcast(
          "driver:" <> next_taxi.nickname,
          "booking_request",
          %{
            msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
            bookingId: booking_id
          }
        )

        timer_ref = Process.send_after(self(), :timeout, 5000)

        {:noreply, %{state |
          contacted_taxi: next_taxi,
          remaining_candidates: rest,
          failed_attempts: new_failed,
          timer_ref: timer_ref
        }}
    end
  end

  def candidate_taxis() do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "pippin", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end
end
