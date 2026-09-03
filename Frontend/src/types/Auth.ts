import type { Session, User } from "@supabase/supabase-js";

export type Role = 
    "admin" | 
    "manager" | 
    "user" | 
    null;

export type AuthState = {
  user: User | null;
  session: Session | null;
  role: Role;
  loading: boolean;
  signOut: () => Promise<void>;
  refreshRole: () => Promise<void>;
};
