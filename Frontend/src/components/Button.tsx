import type { ReactNode } from"react";

interface Props {
  className?: string;
  onClick?: () => void;
  message: ReactNode;
  type?: "button" | "submit" | "reset";
  disabled?: boolean;
}

export default function Button ({ className, onClick, message, type, disabled }: Props) {
    return (
        <button
            className={className}
            onClick={onClick}
            type={type}
            disabled={disabled}
        >
            {message}
        </button>
    )
}