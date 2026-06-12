import {useEffect, useState} from 'react';
import Button from '@mui/material/Button'

import socket from '../services/taxi_socket';
import { TextField } from '@mui/material';

function Customer(props) {
  let [pickupAddress, setPickupAddress] = useState("Tecnologico de Monterrey, campus Puebla, Mexico");
  let [dropOffAddress, setDropOffAddress] = useState("Triangulo Las Animas, Puebla, Mexico");
  let [msg, setMsg] = useState("");
  let [msg1, setMsg1] = useState("");
  let [bookingId, setBookingId] = useState(null);
  let [canCancel, setCanCancel] = useState(false);

  useEffect(() => {
    let channel = socket.channel("customer:" + props.username, {token: "123"});

    channel.on("greetings", data => console.log(data));
    channel.on("booking_request", dataFromPush => {
      console.log("Received", dataFromPush);
      setMsg1(dataFromPush.msg);

      if (dataFromPush.bookingId) {
        setBookingId(dataFromPush.bookingId);
      }

      if (dataFromPush.status === "accepted") {
        setCanCancel(true);
      }

      if (dataFromPush.status === "eta_update") {
        setCanCancel(true);
      }

      if (["arrived", "cancelled", "failed", "closed"].includes(dataFromPush.status)) {
        setCanCancel(false);
        setBookingId(null);
      }
    });

    channel.join();

    return () => {
      channel.leave();
    };
  },[props.username]);

  let submit = () => {
    console.log("Submit clicked");

    const request = fetch(`http://localhost:4000/api/bookings`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pickup_address: pickupAddress, dropoff_address: dropOffAddress, username: props.username})
    });

    console.log("Request send");

    request
      .then(resp => resp.json())
      .then(dataFromPOST => {
        if (dataFromPOST.bookingId) {
          setBookingId(dataFromPOST.bookingId);
        }

        setCanCancel(false);
        setMsg(dataFromPOST.msg);
      });
  };

  let cancel = () => {
    if (!bookingId) return;
    setCanCancel(false);

    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: "cancel", username: props.username})
    }).then(resp => resp.json()).then(data => {
      setMsg(data.msg);

      if (data.status === "not_found") {
        setBookingId(null);
      }
    });
  };

  let timeSkip = () => {
    if (!bookingId) return;

    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: "time_skip", username: props.username})
    }).then(resp => resp.json()).then(data => {
      if (data.status === "not_found") {
        setMsg(data.msg);
        setCanCancel(false);
        setBookingId(null);
      }
    });
  };

  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
      Customer: {props.username}
      <div>
          <TextField id="outlined-basic" label="Pickup address"
            fullWidth
            onChange={ev => setPickupAddress(ev.target.value)}
            value={pickupAddress}/>
          <TextField id="outlined-basic" label="Drop off address"
            fullWidth
            onChange={ev => setDropOffAddress(ev.target.value)}
            value={dropOffAddress}/>
        <Button onClick={submit} variant="outlined" color="primary">Submit</Button>
        {canCancel && bookingId && (
          <>
            <Button onClick={cancel} variant="outlined" color="error" style={{marginLeft: "8px"}}>
              Cancel Booking
            </Button>
            <Button onClick={timeSkip} variant="outlined" color="secondary" style={{marginLeft: "8px"}}>
              Time skip
            </Button>
          </>
        )}
      </div>
      <div style={{backgroundColor: "lightcyan", height: "50px"}}>
        {msg}
      </div>
      <div style={{backgroundColor: "lightblue", height: "50px"}}>
        {msg1}
      </div>
    </div>
  );
}

export default Customer;
