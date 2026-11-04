-- Lançamentos feitos pelo site (LBO Finanças Web): o app do iPhone aplica e apaga quando abre.
-- Rodar uma vez no Supabase: SQL Editor → New query → colar → Run.
create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('gasto', 'receita', 'transferir', 'paguei')),
  dados jsonb not null,
  criado_em timestamptz not null default now()
);

alter table public.pedidos enable row level security;

drop policy if exists "pedidos: dono le" on public.pedidos;
drop policy if exists "pedidos: dono cria" on public.pedidos;
drop policy if exists "pedidos: dono apaga" on public.pedidos;

create policy "pedidos: dono le" on public.pedidos
  for select to authenticated using (auth.uid() = user_id);
create policy "pedidos: dono cria" on public.pedidos
  for insert to authenticated with check (auth.uid() = user_id);
create policy "pedidos: dono apaga" on public.pedidos
  for delete to authenticated using (auth.uid() = user_id);

grant select, insert, delete on public.pedidos to authenticated;
