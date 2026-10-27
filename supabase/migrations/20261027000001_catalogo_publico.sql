-- Paso 1 (aditivo, se puede aplicar antes de subir el sitio nuevo).
-- El catálogo público deja de leer la tabla completa (que trae ventas, clientes y costos)
-- y pasa a pedir solo lo que se muestra al cliente: esta función.

create or replace function public.catalogo_publico()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          p -> 'id',
           'nombre',      p -> 'nombre',
           'tipo',        p -> 'tipo',
           'precioVenta', p -> 'precioVenta',
           'stock',       p -> 'stock',
           'vendidos',    p -> 'vendidos',
           'fotoUrl',     p -> 'fotoUrl'
         )), '[]'::jsonb)
  from public.mi_tienda_sync t,
       jsonb_array_elements(t.productos) p
  where t.id = 1
    and case when jsonb_typeof(p -> 'stock') = 'number'
             then (p ->> 'stock')::numeric > 0
             else false end;
$$;

revoke all on function public.catalogo_publico() from public;
grant execute on function public.catalogo_publico() to anon, authenticated;
