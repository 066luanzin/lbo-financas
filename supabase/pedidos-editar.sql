-- Libera editar e apagar transação pelo site. Rodar uma vez no SQL Editor do Supabase.
alter table public.pedidos drop constraint if exists pedidos_tipo_check;
alter table public.pedidos add constraint pedidos_tipo_check
  check (tipo in ('gasto', 'receita', 'transferir', 'paguei', 'editar', 'apagar'));
