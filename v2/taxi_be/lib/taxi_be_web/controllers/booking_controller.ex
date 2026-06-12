defmodule TaxiBeWeb.BookingController do
  use TaxiBeWeb, :controller

  alias TaxiBeWeb.TaxiAllocationJob

  # Crea una nueva reservación. Genera un UUID único como booking_id, lanza un
  # GenServer (TaxiAllocationJob) registrado con ese ID para manejar el proceso
  # de asignación de forma asíncrona, y retorna 201 con el header Location
  # apuntando al recurso recién creado.
  def create(conn, req) do
    booking_id = UUID.uuid1()
    ride_info = TaxiAllocationJob.ride_info(req)
    booking_request =
      req
      |> Map.merge(ride_info)
      |> Map.put("booking_id", booking_id)

    TaxiAllocationJob.start(
      booking_request,
      String.to_atom(booking_id)
    )

    conn
    |> put_resp_header("Location", "/api/bookings/" <> booking_id)
    |> put_status(:created)
    |> json(%{
      msg: "Tarifa estimada: $#{format_money(ride_info["fare"])}. Estamos buscando un taxi.",
      bookingId: booking_id,
      fare: ride_info["fare"],
      rideDistanceKm: ride_info["ride_distance_km"]
    })
  end

  # El taxista acepta la oferta. Se busca el GenServer por el booking_id (que viene
  # como ":id" en la ruta) y se le envía un cast asíncrono para continuar el flujo.
  # Se usa cast (no call) porque el controlador no necesita esperar respuesta.
  def update(conn, %{"action" => "accept", "username" => username, "id" => id}) do
    if cast_booking_action(id, {:process_accept, username}) do
      json(conn, %{msg: "We will process your acceptance"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{msg: "This booking is no longer active"})
    end
  end

  # Rechazo y cancelación quedan registrados en el log del servidor. En una versión
  # futura se debería reintentar con otro taxista (reject) o terminar el proceso (cancel).
  def update(conn, %{"action" => "reject", "username" => username, "id" => id}) do
    if cast_booking_action(id, {:process_reject, username}) do
      json(conn, %{msg: "We will process your rejection"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{msg: "This booking is no longer active"})
    end
  end

  def update(conn, %{"action" => "cancel", "username" => username, "id" => _id}) do
    IO.inspect("'#{username}' is cancelling a booking request")
    json(conn, %{msg: "We will process your cancelation"})
  end

  defp cast_booking_action(id, message) do
    process_name = String.to_existing_atom(id)

    if Process.whereis(process_name) do
      GenServer.cast(process_name, message)
      true
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  defp format_money(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp format_money(amount), do: amount
end
