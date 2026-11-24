-- Backup na nuvem do LBO Finanças: uma linha por usuário com todos os dados dele.
-- Rodar uma vez no Supabase: SQL Editor → New query → colar → Run.
create table if not exists public.backups (
  user_id uuid primary key references auth.users(id) on delete cascade,
  dados jsonb not null,
  atualizado_em timestamptz not null default now()
);

alter table public.backups enable row level security;

drop policy if exists "backup: dono le" on public.backups;
drop policy if exists "backup: dono cria" on public.backups;
drop policy if exists "backup: dono atualiza" on public.backups;

create policy "backup: dono le" on public.backups
  for select to authenticated using (auth.uid() = user_id);
create policy "backup: dono cria" on public.backups
  for insert to authenticated with check (auth.uid() = user_id);
create policy "backup: dono atualiza" on public.backups
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

grant select, insert, update on public.backups to authenticated;

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

-- Libera todos os tipos de mudança que o site manda (contas, ajustes, caixinhas, config...).
-- Rodar uma vez no SQL Editor do Supabase.
alter table public.pedidos drop constraint if exists pedidos_tipo_check;

-- Permite que o próprio usuário exclua a conta pelo app (Config → Excluir conta).
-- Rodar uma vez no Supabase: SQL Editor → New query → colar → Run.
create or replace function public.excluir_conta()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from auth.users where id = auth.uid();
$$;

revoke all on function public.excluir_conta() from public, anon;
grant execute on function public.excluir_conta() to authenticated;

-- Consulta simples pra automação diária manter o projeto ativo
create or replace function public.ping()
returns int
language sql
stable
as $$ select 1 $$;

grant execute on function public.ping() to anon, authenticated;
