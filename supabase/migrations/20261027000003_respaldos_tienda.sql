-- Paso 3: copias automáticas de la tienda.
-- Todo el inventario, las ventas y el historial viven en UNA fila de mi_tienda_sync, así que un
-- borrado accidental o un error del código no se podía deshacer. Este paso guarda la versión
-- anterior cada vez que algo cambia:
--   · 'borrado'   → siempre que baje la cantidad de productos, ventas o historial
--   · 'periodico' → como máximo una vez cada 10 minutos cuando cambia cualquier dato
--   · 'inicial'   → una copia del estado en que se instaló
-- Se conservan como máximo las últimas 400 copias (la fila pesa ~44 kB: ~17 MB). El límite de 60 días
-- se aplica al crear la siguiente copia, no por tiempo.
-- Si el respaldo falla —incluso por esperar un bloqueo más de 0,5 s— el guardado de la tienda continúa
-- y solo queda un aviso en los logs. (Si el propio servidor cancelara la consulta por tiempo, se cancela todo.)
--
-- Cómo recuperar (en el SQL Editor de Supabase, solo el dueño del proyecto).
-- ANTES de restaurar: cerrar el panel en todos los teléfonos. Un panel abierto con datos viejos los
-- volvería a guardar encima de lo restaurado. Después de restaurar, recargar el panel.
--   1) Ver las copias:
--        select id, respaldado_en, motivo,
--               jsonb_array_length(productos) as productos, jsonb_array_length(ventas) as ventas
--          from public.mi_tienda_sync_historial order by id desc limit 30;
--   2) Restaurar TODO a una copia (primero guarda el estado actual como 'antes_de_restaurar',
--      así se puede deshacer; no depende del disparador):
--        begin;
--        insert into public.mi_tienda_sync_historial (motivo, sync_id, actualizado, productos, ventas, hist)
--          select 'antes_de_restaurar', id, actualizado, productos, ventas, hist
--            from public.mi_tienda_sync where id = 1 for update;
--        update public.mi_tienda_sync t
--           set productos = h.productos, ventas = h.ventas, hist = h.hist, actualizado = now() at time zone 'utc'
--          from public.mi_tienda_sync_historial h where h.id = <ID_DE_LA_COPIA> and t.id = 1;
--        delete from public.mi_tienda_sync_historial   -- mantiene el tope de 400 copias
--         where respaldado_en < now() - interval '60 days'
--            or id <= coalesce((select x.id from public.mi_tienda_sync_historial x order by x.id desc offset 400 limit 1), 0);
--        commit;
--   3) Recuperar solo UN producto borrado. No hace nada si la copia o el producto no existen, o si
--      el producto ya está en la tienda (no lo duplica):
--        update public.mi_tienda_sync t
--           set productos = t.productos || r.encontrado
--          from (select jsonb_agg(x.p) as encontrado
--                  from (select p from public.mi_tienda_sync_historial h, jsonb_array_elements(h.productos) p
--                         where h.id = <ID_DE_LA_COPIA> and p->>'id' = '<ID_DEL_PRODUCTO>' limit 1) x) r
--         where t.id = 1 and r.encontrado is not null
--           and not exists (select 1 from jsonb_array_elements(t.productos) c where c->>'id' = '<ID_DEL_PRODUCTO>');

create table if not exists public.mi_tienda_sync_historial (
  id            bigint generated always as identity primary key,
  respaldado_en timestamptz not null default now(),
  motivo        text not null,
  sync_id       integer not null,
  actualizado   timestamp,
  productos     jsonb,
  ventas        jsonb,
  hist          jsonb
);
create index if not exists mi_tienda_sync_historial_fecha_idx
  on public.mi_tienda_sync_historial (sync_id, respaldado_en desc);

-- Sin políticas y sin permisos: ni la llave pública ni los usuarios con sesión la ven.
-- Solo el dueño del proyecto (SQL Editor) y la función de abajo.
alter table public.mi_tienda_sync_historial enable row level security;
revoke all on public.mi_tienda_sync_historial from anon, authenticated;

create or replace function public.guardar_version_tienda()
returns trigger
language plpgsql
security definer
set search_path = ''
set lock_timeout = '500ms'
as $fn$
declare
  v_motivo text;
begin
  -- Solo cambió la marca de tiempo: no hay nada que respaldar
  if old.productos is not distinct from new.productos
     and old.ventas is not distinct from new.ventas
     and old.hist   is not distinct from new.hist then
    return null;
  end if;

  begin
    if coalesce(jsonb_array_length(case when jsonb_typeof(new.productos) = 'array' then new.productos end), 0)
         < coalesce(jsonb_array_length(case when jsonb_typeof(old.productos) = 'array' then old.productos end), 0)
       or coalesce(jsonb_array_length(case when jsonb_typeof(new.ventas) = 'array' then new.ventas end), 0)
         < coalesce(jsonb_array_length(case when jsonb_typeof(old.ventas) = 'array' then old.ventas end), 0)
       or coalesce(jsonb_array_length(case when jsonb_typeof(new.hist) = 'array' then new.hist end), 0)
         < coalesce(jsonb_array_length(case when jsonb_typeof(old.hist) = 'array' then old.hist end), 0)
    then
      v_motivo := 'borrado';
    elsif not exists (select 1 from public.mi_tienda_sync_historial h
                       where h.sync_id = old.id and h.respaldado_en > now() - interval '10 minutes') then
      v_motivo := 'periodico';
    else
      return null;
    end if;

    insert into public.mi_tienda_sync_historial (motivo, sync_id, actualizado, productos, ventas, hist)
    values (v_motivo, old.id, old.actualizado, old.productos, old.ventas, old.hist);

    delete from public.mi_tienda_sync_historial
     where respaldado_en < now() - interval '60 days'
        or id <= coalesce((select h.id from public.mi_tienda_sync_historial h order by h.id desc offset 400 limit 1), 0);
  exception when others then
    -- Un problema con el respaldo nunca debe impedir que se guarde la tienda
    raise warning 'respaldo de mi_tienda_sync falló: %', sqlerrm;
  end;

  return null;
end;
$fn$;

revoke all on function public.guardar_version_tienda() from public, anon, authenticated;

drop trigger if exists mi_tienda_sync_respaldo on public.mi_tienda_sync;
create trigger mi_tienda_sync_respaldo
  after update on public.mi_tienda_sync
  for each row execute function public.guardar_version_tienda();

-- Copia del estado actual, para tener punto de partida
insert into public.mi_tienda_sync_historial (motivo, sync_id, actualizado, productos, ventas, hist)
select 'inicial', t.id, t.actualizado, t.productos, t.ventas, t.hist
  from public.mi_tienda_sync t
 where not exists (select 1 from public.mi_tienda_sync_historial h where h.motivo = 'inicial');
