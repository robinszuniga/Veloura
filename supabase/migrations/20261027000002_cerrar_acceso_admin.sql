-- Paso 2 (cierra el acceso). Aplicar SOLO cuando el sitio nuevo ya esté publicado
-- y exista el usuario administrador con app_metadata.role = 'admin'.
-- Antes: cualquiera con la llave pública podía leer ventas/clientes, reescribir la tabla
-- y subir o borrar fotos. Después: solo el administrador autenticado.

-- ── Tabla mi_tienda_sync ────────────────────────────────────────────────
drop policy if exists "Admin puede actualizar"            on public.mi_tienda_sync;
drop policy if exists "Enable read access for all users"  on public.mi_tienda_sync;

-- Las políticas solo mandan si RLS está activo: se asegura aquí (ya estaba, es idempotente).
alter table public.mi_tienda_sync enable row level security;

revoke all on public.mi_tienda_sync from anon;
revoke all on public.mi_tienda_sync from authenticated;
grant select, update on public.mi_tienda_sync to authenticated;

-- El rol sale de app_metadata, que el usuario no puede editar desde el navegador
-- (user_metadata sí). Un registro nuevo cualquiera no pasa estas políticas.
create policy admin_select on public.mi_tienda_sync
  for select to authenticated
  using ((select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

create policy admin_update on public.mi_tienda_sync
  for update to authenticated
  using      (id = 1 and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check (id = 1 and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- ── Storage: bucket "fotos" ─────────────────────────────────────────────
-- El bucket es público: las URLs de las fotos siguen abiertas para el catálogo.
-- Lo que se cierra es subir, reemplazar y borrar.
drop policy if exists fotos_allow_all   on storage.objects;
drop policy if exists fotos_acceso_total on storage.objects;

create policy fotos_admin_select on storage.objects
  for select to authenticated
  using (bucket_id = 'fotos' and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

create policy fotos_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'fotos' and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

create policy fotos_admin_update on storage.objects
  for update to authenticated
  using      (bucket_id = 'fotos' and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check (bucket_id = 'fotos' and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

create policy fotos_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'fotos' and (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

update storage.buckets
   set file_size_limit    = 2097152,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'fotos';
