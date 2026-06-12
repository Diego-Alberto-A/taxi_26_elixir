defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  @driver_response_timeout 90_000
  @base_fare 25.0
  @fare_per_km 10.0
  @average_driver_speed_kmh 25.0

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def start(request, name) do
    GenServer.start(__MODULE__, request, name: name)
  end

  def ride_info(request) do
    pickup_coords = address_coordinates(request["pickup_address"])
    dropoff_coords = address_coordinates(request["dropoff_address"])
    distance_km = distance_km(pickup_coords, dropoff_coords)
    fare = calculate_fare(distance_km)

    %{
      "fare" => fare,
      "ride_distance_km" => Float.round(distance_km, 2)
    }
  end

  def init(request) do
    Process.send(self(), :start_allocation, [:nosuspend])
    {:ok, %{request: request}}
  end

  def handle_info(:start_allocation, %{request: request}) do
    candidates = find_candidate_taxis()
    selected_taxis = select_three_closest_taxis(candidates, request["pickup_address"])

    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    Enum.each(selected_taxis, fn taxi ->
      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> taxi.nickname,
        "booking_request",
        %{
          msg:
            "Viaje de '#{pickup_address}' a '#{dropoff_address}'. Tarifa: $#{format_money(request["fare"])}",
          bookingId: booking_id,
          fare: request["fare"]
        }
      )
    end)

    timer_ref = Process.send_after(self(), :timeout, @driver_response_timeout)

    {:noreply,
     %{
       request: request,
       contacted_taxis: selected_taxis |> Enum.map(& &1.nickname) |> MapSet.new(),
       rejected_drivers: MapSet.new(),
       timer_ref: timer_ref,
       active: true
     }}
  end

  def handle_info(:timeout, state) do
    if state.active do
      notify_no_taxi(state)
      notify_drivers_booking_closed(state, "failed")
      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:process_accept, driver_username}, state) do
    if state.active and MapSet.member?(state.contacted_taxis, driver_username) and
         not MapSet.member?(state.rejected_drivers, driver_username) do
      Process.cancel_timer(state.timer_ref)
      notify_customer_taxi_assigned(state, driver_username)
      notify_drivers_booking_closed(state, "accepted", driver_username)
      {:noreply, %{state | active: false}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:process_reject, driver_username}, state) do
    if state.active and MapSet.member?(state.contacted_taxis, driver_username) and
         not MapSet.member?(state.rejected_drivers, driver_username) do
      rejected_drivers = MapSet.put(state.rejected_drivers, driver_username)

      notify_driver_booking_closed(state, driver_username, "rejected")
      {:noreply, %{state | rejected_drivers: rejected_drivers}}
    else
      {:noreply, state}
    end
  end

  defp notify_customer_taxi_assigned(state, driver_username) do
    eta_minutes = estimated_arrival_minutes(driver_username, state.request["pickup_address"])

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> state.request["username"],
      "booking_request",
      %{
        msg:
          "Tu taxi (#{driver_username}) esta en camino. Tarifa: $#{format_money(state.request["fare"])}. Tiempo estimado de llegada: #{eta_minutes} minuto(s).",
        bookingId: state.request["booking_id"],
        status: "accepted",
        acceptedDriver: driver_username,
        fare: state.request["fare"],
        estimatedArrivalMinutes: eta_minutes
      }
    )
  end

  defp notify_no_taxi(state) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> state.request["username"],
      "booking_request",
      %{
        msg: "Lo sentimos, no fue posible asignarte un taxi en este momento.",
        bookingId: state.request["booking_id"],
        status: "failed"
      }
    )
  end

  defp notify_drivers_booking_closed(state, status, accepted_driver \\ nil) do
    Enum.each(state.contacted_taxis, fn driver_username ->
      notify_driver_booking_closed(state, driver_username, status, accepted_driver)
    end)
  end

  defp notify_driver_booking_closed(state, driver_username, status, accepted_driver \\ nil) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> driver_username,
      "booking_request_closed",
      %{
        bookingId: state.request["booking_id"],
        status: status,
        acceptedDriver: accepted_driver
      }
    )
  end

  defp find_candidate_taxis() do
    candidate_taxis()
  end

  defp select_three_closest_taxis(candidates, pickup_address) do
    pickup_coords = address_coordinates(pickup_address)

    candidates
    |> Enum.sort_by(fn taxi -> distance_km({taxi.latitude, taxi.longitude}, pickup_coords) end)
    |> Enum.take(3)
  end

  defp estimated_arrival_minutes(driver_username, pickup_address) do
    pickup_coords = address_coordinates(pickup_address)
    taxi = Enum.find(candidate_taxis(), &(&1.nickname == driver_username))

    case taxi do
      nil ->
        1

      taxi ->
        distance = distance_km({taxi.latitude, taxi.longitude}, pickup_coords)
        max(1, ceil(distance / @average_driver_speed_kmh * 60))
    end
  end

  defp calculate_fare(distance_km) do
    (@base_fare + distance_km * @fare_per_km)
    |> max(35.0)
    |> Float.round(2)
  end

  defp address_coordinates(address) when is_binary(address) do
    normalized = String.downcase(address)

    cond do
      String.contains?(normalized, "tecnologico") or String.contains?(normalized, "monterrey") ->
        {19.0319, -98.2423}

      String.contains?(normalized, "triangulo") or String.contains?(normalized, "animas") ->
        {19.0511, -98.2301}

      true ->
        {19.0433, -98.2019}
    end
  end

  defp address_coordinates(_address), do: {19.0433, -98.2019}

  defp distance_km({lat1, lon1}, {lat2, lon2}) do
    earth_radius_km = 6_371
    dlat = degrees_to_radians(lat2 - lat1)
    dlon = degrees_to_radians(lon2 - lon1)
    lat1 = degrees_to_radians(lat1)
    lat2 = degrees_to_radians(lat2)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1) * :math.cos(lat2) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    earth_radius_km * c
  end

  defp degrees_to_radians(degrees), do: degrees * :math.pi() / 180

  defp format_money(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp format_money(amount), do: amount

  def candidate_taxis() do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "pippin", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end
end
