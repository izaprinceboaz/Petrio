import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import type { AuthState, Role } from "../types/Auth";


const AuthContext = createContext<AuthState | undefined>(undefined);

// Read role from JWT app_metadata / custom claim first, fall back to profiles table.
async function resolveRole(session: Session | null): Promise<Role> {
  if (!session?.user) return null;

  const claim =
    (session.user.app_metadata as Record<string, unknown> | undefined)?.role ??
    (session.user.user_metadata as Record<string, unknown> | undefined)?.role;
  if (typeof claim === "string") return claim as Role;

  const { data, error } = await supabase
    .from("profiles")
    .select("role")
    .eq("id", session.user.id)
    .single();

  if (error) return null;
  return (data?.role ?? null) as Role;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [role, setRole] = useState<Role>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;

    supabase.auth.getSession().then(async ({ data }) => {
      if (!active) return;
      setSession(data.session);
      setRole(await resolveRole(data.session));
      setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange(async (_e, next) => {
      if (!active) return;
      setSession(next);
      setRole(await resolveRole(next));
      setLoading(false);
    });

    return () => {
      active = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const value = useMemo<AuthState>(
    () => ({
      user: session?.user ?? null,
      session,
      role,
      loading,
      signOut: async () => {
        await supabase.auth.signOut();
        setSession(null);
        setRole(null);
      },
      refreshRole: async () => setRole(await resolveRole(session)),
    }),
    [session, role, loading]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within an AuthProvider");
  return ctx;
}