import { Route, Routes } from 'react-router-dom'
import Account from './pages/account/Account'
import LogIn from './pages/auth/LogIn'
import SignUp from './pages/auth/SignUp'
import MainLayout from './layout/MainLayout'
import './App.css'
import RequireRole from './layout/RequireRoleLayout'
import ShiftEntry from './pages/pompiste/ShiftEntry'
import Bonuses from './pages/Bonuses/Bonuses'
import ShiftEntryImport from './pages/ShiftEntryImport/ShiftEntryImport'
import PompisteShiftEntry from './pages/PompisteShiftEntry/PompisteShiftEntry'
import Stock from './pages/Stock/Stock'
import Situation from './pages/Situation/Situation'
import Settings from './pages/Settings/Settings'

function App() {

  return (
    <Routes>
      <Route element={<MainLayout/>}>
        <Route path="/account" element={<Account/>}/>
        <Route path="/bonuses" element={<Bonuses/>}/>
        <Route path="/pompiste-shift-entry" element={<PompisteShiftEntry/>}/>
        <Route path="/shift-entry-import" element={<ShiftEntryImport/>}/>
        <Route path="/stock" element={<Stock/>}/>
        <Route path="/situation" element={<Situation/>}/>
        <Route path="/settings" element={<Settings/>}/>
      </Route>
      <Route path="/login" element={<LogIn/>}/>
      <Route path="/signup" element={<SignUp />}/>
    </Routes>
  )
}

export default App
