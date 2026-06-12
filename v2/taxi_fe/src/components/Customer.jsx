import React, {useEffect, useRef, useState} from 'react';
import Button from '@mui/material/Button'

import socket from '../services/taxi_socket';
import { TextField } from '@mui/material';

function Customer(props) {
  let [pickupAddress, setPickupAddress] = useState("Tecnologico de Monterrey, campus Puebla, Mexico");
  let [dropOffAddress, setDropOffAddress] = useState("Triangulo Las Animas, Puebla, Mexico");
  let [msg, setMsg] = useState("");
  let [msg1, setMsg1] = useState("");
  let activeBookingIdRef = useRef();
  let timeoutRef = useRef();

  let clearBookingTimeout = (bookingId) => {
    if (!bookingId || activeBookingIdRef.current === bookingId) {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }

      timeoutRef.current = undefined;
      activeBookingIdRef.current = undefined;
    }
  };

  let scheduleBookingTimeout = (bookingId) => {
    clearBookingTimeout();
    activeBookingIdRef.current = bookingId;

    timeoutRef.current = setTimeout(() => {
      if (activeBookingIdRef.current === bookingId) {
        setMsg1("Lo sentimos, no fue posible asignarte un taxi en este momento.");
        clearBookingTimeout(bookingId);
      }
    }, 90_000);
  };

  useEffect(() => {
    let channel = socket.channel("customer:" + props.username, {token: "123"});
    channel.on("greetings", data => console.log(data));
    channel.on("booking_request", dataFromPush => {
      console.log("Received", dataFromPush);
      setMsg1(dataFromPush.msg);

      if (dataFromPush.status === "accepted" || dataFromPush.status === "failed") {
        clearBookingTimeout(dataFromPush.bookingId);
      }
    });
    channel.join();

    return () => {
      clearBookingTimeout();
      channel.leave();
    };
  },[props.username]);

  let submit = () => {
    fetch(`http://localhost:4000/api/bookings`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pickup_address: pickupAddress, dropoff_address: dropOffAddress, username: props.username})
    }).then(resp => resp.json()).then(dataFromPOST => {
      setMsg(dataFromPOST.msg);
      setMsg1("");

      if (dataFromPOST.bookingId) {
        scheduleBookingTimeout(dataFromPOST.bookingId);
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
