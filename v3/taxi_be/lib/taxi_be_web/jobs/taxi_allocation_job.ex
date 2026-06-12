defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  @eta_minutes 5
  # Penalty threshold: cancel is free if taxi is more than 3 min away
  @penalty_threshold_minutes 3
  @service_log_path Path.expand("../../../service_log.txt", __DIR__)

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

    {:noreply,
     %{
       request: request,
       contacted_taxis: Enum.map(candidates, & &1.nickname) |> MapSet.new(),
       rejected_drivers: MapSet.new(),
       timer_ref: timer_ref,
       eta_timer_ref: nil,
       phase: :awaiting_acceptance,
       accepted_driver: nil,
       arrives_at: nil,
       active: true
     }}
  end

  # No driver accepted within 1.5 minutes.
  def handle_info(:timeout, state) do
    if state.active do
      log_unsuccessful_service(state, "failed_acceptance_timeout", %{timeout_seconds: 90})
      notify_no_taxi(state.request["username"])
      notify_drivers_booking_closed(state, "failed")
      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  # Taxi has arrived — trip starts normally. Close the booking.
  def handle_info(:taxi_arrived, state) do
    if state.active do
      cancel_timer(state.eta_timer_ref)
      customer_username = state.request["username"]

      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> customer_username,
        "booking_request",
        %{
          msg: "Tu taxi (#{state.accepted_driver}) ha llegado. ¡Buen viaje!",
          bookingId: state.request["booking_id"],
          status: "arrived"
        }
      )

      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:eta_tick, state) do
    if state.active and state.phase == :awaiting_arrival do
      remaining_seconds = max(state.arrives_at - System.monotonic_time(:second), 0)

      if remaining_seconds <= 0 do
        Process.send(self(), :taxi_arrived, [:nosuspend])
        {:noreply, %{state | eta_timer_ref: nil}}
      else
        send_eta_update(state)
        eta_timer_ref = Process.send_after(self(), :eta_tick, 30_000)
        {:noreply, %{state | eta_timer_ref: eta_timer_ref}}
      end
    else
      {:noreply, state}
    end
  end

  # First driver to accept wins. Cancel timer, notify customer, move to
  # awaiting_arrival phase. Any later acceptances are ignored.
  def handle_cast({:process_accept, driver_username}, state) do
    if state.active and state.phase == :awaiting_acceptance and
         MapSet.member?(state.contacted_taxis, driver_username) do
      Process.cancel_timer(state.timer_ref)
      customer_username = state.request["username"]
      booking_id = state.request["booking_id"]
      arrival_at = System.system_time(:second) + @eta_minutes * 60

      notify_drivers_booking_closed(state, "accepted", driver_username)

      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> customer_username,
        "booking_request",
        %{
          msg:
            "Tu taxi (#{driver_username}) está en camino. Tiempo estimado: #{@eta_minutes} minutos.",
          bookingId: booking_id,
          status: "accepted",
          acceptedDriver: driver_username,
          etaMinutes: @eta_minutes,
          arrivalAt: arrival_at
        }
      )

      # Arrival timer: when this fires the taxi has arrived and the trip starts
      arrival_timer_ref = Process.send_after(self(), :taxi_arrived, @eta_minutes * 60_000)
      eta_timer_ref = Process.send_after(self(), :eta_tick, 30_000)

      {:noreply,
       %{
         state
         | phase: :awaiting_arrival,
           accepted_driver: driver_username,
           arrives_at: System.monotonic_time(:second) + @eta_minutes * 60,
           timer_ref: arrival_timer_ref,
           eta_timer_ref: eta_timer_ref
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

        log_unsuccessful_service(state, "failed_all_drivers_rejected", %{
          rejected_drivers: MapSet.to_list(new_rejected_drivers)
        })

        notify_no_taxi(state.request["username"])
        notify_drivers_booking_closed(state, "failed")
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
      TaxiBeWeb.Endpoint.broadcast(
        "customer:" <> state.request["username"],
        "booking_request",
        %{
          msg: "La reservación ya no está activa.",
          bookingId: state.request["booking_id"],
          status: "closed"
        }
      )

      {:noreply, state}
    else
      Process.cancel_timer(state.timer_ref)
      cancel_timer(state.eta_timer_ref)
      customer_username = state.request["username"]

      case state.phase do
        :awaiting_acceptance ->
          # No driver has accepted yet — cancel with no penalty
          log_unsuccessful_service(state, "cancelled_before_acceptance", %{penalty: 0})
          notify_drivers_booking_closed(state, "cancelled")

          TaxiBeWeb.Endpoint.broadcast(
            "customer:" <> customer_username,
            "booking_request",
            %{
              msg: "Reservación cancelada sin penalización.",
              bookingId: state.request["booking_id"],
              status: "cancelled"
            }
          )

          {:noreply, %{state | active: false}}

        :awaiting_arrival ->
          # Compute how many minutes remain until the taxi arrives.
          remaining_seconds = max(state.arrives_at - System.monotonic_time(:second), 0)
          remaining_minutes = remaining_seconds / 60

          if remaining_minutes > @penalty_threshold_minutes do
            log_unsuccessful_service(state, "cancelled_after_acceptance", %{
              accepted_driver: state.accepted_driver,
              remaining_minutes: Float.round(remaining_minutes, 1),
              penalty: 0
            })

            TaxiBeWeb.Endpoint.broadcast(
              "customer:" <> customer_username,
              "booking_request",
              %{
                msg:
                  "Reservación cancelada sin penalización. El taxi aún está a más de #{@penalty_threshold_minutes} minutos.",
                bookingId: state.request["booking_id"],
                status: "cancelled"
              }
            )
          else
            log_unsuccessful_service(state, "late_cancellation_penalty", %{
              accepted_driver: state.accepted_driver,
              remaining_minutes: Float.round(remaining_minutes, 1),
              penalty: 20
            })

            TaxiBeWeb.Endpoint.broadcast(
              "customer:" <> customer_username,
              "booking_request",
              %{
                msg:
                  "Reservación cancelada con penalización de $20. El taxi estaba a #{Float.round(remaining_minutes, 1)} minuto(s) de distancia.",
                bookingId: state.request["booking_id"],
                status: "cancelled"
              }
            )
          end

          {:noreply, %{state | active: false}}
      end
    end
  end

  def handle_cast({:process_time_skip, seconds}, state) do
    if state.active and state.phase == :awaiting_arrival do
      cancel_timer(state.timer_ref)
      new_arrives_at = state.arrives_at - seconds
      remaining_seconds = max(new_arrives_at - System.monotonic_time(:second), 0)

      if remaining_seconds <= 0 do
        Process.send(self(), :taxi_arrived, [:nosuspend])
        {:noreply, %{state | arrives_at: new_arrives_at, timer_ref: nil}}
      else
        timer_ref = Process.send_after(self(), :taxi_arrived, remaining_seconds * 1_000)
        send_eta_update(%{state | arrives_at: new_arrives_at})

        {:noreply, %{state | arrives_at: new_arrives_at, timer_ref: timer_ref}}
      end
    else
      {:noreply, state}
    end
  end

  defp notify_no_taxi(customer_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer_username,
      "booking_request",
      %{msg: "Lo sentimos, no fue posible asignarte un taxi en este momento.", status: "failed"}
    )
  end

  defp notify_drivers_booking_closed(state, status, accepted_driver \\ nil) do
    Enum.each(state.contacted_taxis, fn driver_username ->
      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> driver_username,
        "booking_request_closed",
        %{
          bookingId: state.request["booking_id"],
          status: status,
          acceptedDriver: accepted_driver
        }
      )
    end)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp send_eta_update(state) do
    remaining_seconds = max(state.arrives_at - System.monotonic_time(:second), 0)
    eta_minutes = ceil(remaining_seconds / 30) / 2

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> state.request["username"],
      "booking_request",
      %{
        msg:
          "Tu taxi (#{state.accepted_driver}) está en camino. Tiempo estimado: #{format_minutes(eta_minutes)} minutos.",
        bookingId: state.request["booking_id"],
        status: "eta_update",
        acceptedDriver: state.accepted_driver,
        etaMinutes: eta_minutes
      }
    )
  end

  defp format_minutes(minutes) when is_float(minutes) and minutes == trunc(minutes) do
    Integer.to_string(trunc(minutes))
  end

  defp format_minutes(minutes) when is_float(minutes) do
    :erlang.float_to_binary(minutes, decimals: 1)
  end

  defp format_minutes(minutes), do: Integer.to_string(minutes)

  defp log_unsuccessful_service(state, outcome, details) do
    request = state.request

    log_entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      booking_id: request["booking_id"],
      customer: request["username"],
      pickup_address: request["pickup_address"],
      dropoff_address: request["dropoff_address"],
      contacted_taxis: MapSet.to_list(state.contacted_taxis),
      outcome: outcome,
      details: details
    }

    line = inspect(log_entry, pretty: false) <> "\n"

    case File.write(@service_log_path, line, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.warn("Could not write unsuccessful service log: #{inspect(reason)}")
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
