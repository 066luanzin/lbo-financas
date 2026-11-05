-- Libera todos os tipos de mudança que o site manda (contas, ajustes, caixinhas, config...).
-- Rodar uma vez no SQL Editor do Supabase.
alter table public.pedidos drop constraint if exists pedidos_tipo_check;
