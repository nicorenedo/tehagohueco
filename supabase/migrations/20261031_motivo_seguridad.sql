-- Te Hago Hueco · motivo de reporte "Conducción peligrosa o accidente" (31-10-2026)
-- Ejecutar a mano en Supabase > SQL Editor. Idempotente.
alter table public.reports drop constraint if exists reports_reason_check;
alter table public.reports add constraint reports_reason_check
  check (reason in ('falso','dinero','incumplimiento','conducta','seguridad','otro'));
