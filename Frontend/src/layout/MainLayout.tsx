import { Outlet, useNavigate } from "react-router-dom";
import NavLinks from "../components/NavLinks";

export default function MainLayout() {
  const navigate = useNavigate();


  function handleLogout() {
    // const refreshToken = localStorage.getItem("refreshToken");
    // if (refreshToken) logout(refreshToken).catch(console.error);
    localStorage.removeItem("accessToken");
    localStorage.removeItem("refreshToken");
    localStorage.removeItem("user");
    navigate("/login");
  }

  // const linkClass = ({ isActive }: { isActive: boolean }) =>
  // isActive ? "sidebar-link active" : "sidebar-link";

  return (
    <div className="layout">
      <nav className="sidebar">
        <div className="sidebar-brand">
          <span className="sidebar-brand-mark">P</span>
          Petrio
        </div>

        <div className="sidebar-links">
          <NavLinks to="/account" roles="manager" label="Account" />
          <NavLinks to="/bonuses" roles="manager" label="Bonuses" />
          <NavLinks to="/account" roles="manager" label="Account" />
          <NavLinks to="/shift-entry-import" roles="manager" label="Shift Entry Import" />
          <NavLinks to="/pompiste-shift-entry" roles="manager" label="Pompiste Shift Entry" />
          <NavLinks to="/stock" roles="manager" label="Stock" />
          <NavLinks to="/situation" roles="manager" label="Situation" />
          <NavLinks to="/settings" roles="manager" label="Settings" />
          
        </div>

        <button className="sidebar-logout" onClick={handleLogout}>Log out</button>
      </nav>

      <main className="layout-content">
        <Outlet />
      </main>
    </div>
  );
}
