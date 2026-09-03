import { Navigate, NavLink } from "react-router-dom";

interface Props {
    roles: "owner" | "manager" | "pompiste";
    to: string;
    className?: string;
    label: string;
}

export default function NavLinks({roles, to, className, label}: Props) {
    const role = localStorage.getItem("role") ?? "";

    if (!roles.includes(role)) {
        return <Navigate to="/login" replace />;
    }

    return (
        <NavLink to={to} className={className}> 
            {label}
        </NavLink>
    )
}