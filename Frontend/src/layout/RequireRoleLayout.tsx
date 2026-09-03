import { Navigate, Outlet } from "react-router-dom";

interface Props {
    roles: "owner" | "manager" | "pompiste";
}

export default function RequireRole({roles}: Props) {
    const role = localStorage.getItem("role") ?? "";
    if (!roles.includes(role)) {
        return <Navigate to="/login" replace />;
    }
    return <Outlet/>
}