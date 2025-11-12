import React, { useEffect, useState } from 'react'
import ReactDOM from 'react-dom/client'
import axios from 'axios'

const API_INV  = '/api/investigation/health'
const API_UBA  = '/api/analytics/health'

function App(){
  const [inv, setInv] = useState('Checking')
  const [uba, setUba] = useState('Checking')
  useEffect(()=>{
    axios.get(API_INV).then(r=>setInv(JSON.stringify(r.data))).catch(()=>setInv('DOWN'))
    axios.get(API_UBA).then(r=>setUba(JSON.stringify(r.data))).catch(()=>setUba('DOWN'))
  },[])
  return (<div style={{padding:20,fontFamily:'Arial'}}>
    <h2>FFactory Investigation Cockpit</h2>
    <p>Investigation API: <b>{inv}</b></p>
    <p>Behavioral Analytics: <b>{uba}</b></p>
  </div>)
}
ReactDOM.createRoot(document.getElementById('root')).render(<App/>)
