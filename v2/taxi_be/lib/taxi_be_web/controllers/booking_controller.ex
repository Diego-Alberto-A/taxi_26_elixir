defmodule TaxiBeWeb.BookingController do
  use TaxiBeWeb, :controller

  alias TaxiBeWeb.TaxiAllocationJob

  # Crea una nueva reservación. Genera un UUID único como booking_id, lanza un
  # GenServer (TaxiAllocationJob) registrado con ese ID para manejar el proceso
  # de asignación de forma asíncrona, y retorna 201 con el header Location
  # apuntando al recurso recién creado.
  def create(conn, req) do
    booking_id = UUID.uuid1()

    TaxiAllocationJob.start_link(
      req |> Map.put("booking_id", booking_id),
      String.to_atom(booking_id)
    )

    conn
    |> put_resp_header("Location", "/api/bookings/" <> booking_id)
    |> put_status(:created)
    |> json(%{msg: "We are processing your request"})
  end

  # El taxista acepta la oferta. Se busca el GenServer por el booking_id (que viene
  # como ":id" en la ruta) y se le envía un cast asíncrono para continuar el flujo.
  # Se usa cast (no call) porque el controlador no necesita esperar respuesta.
  def update(conn, %{"action" => "accept", "username" => username, "id" => id}) do
    GenServer.cast(String.to_atom(id), {:process_accept, username})
    json(conn, %{msg: "We will process your acceptance"})
  end

  # Rechazo y cancelación quedan registrados en el log del servidor. En una versión
  # futura se debería reintentar con otro taxista (reject) o terminar el proceso (cancel).
  def update(conn, %{"action" => "reject", "username" => username, "id" => id}) do
    GenServer.cast(String.to_atom(id), {:process_reject, username})
    json(conn, %{msg: "We will process your rejection"})
  end

  def update(conn, %{"action" => "cancel", "username" => username, "id" => _id}) do
    IO.inspect("'#{username}' is cancelling a booking request")
    json(conn, %{msg: "We will process your cancelation"})
  end
end
