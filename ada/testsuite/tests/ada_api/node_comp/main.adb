with Ada.Text_IO;          use Ada.Text_IO;

with Langkit_Support.Diagnostics; use Langkit_Support.Diagnostics;

with Libadalang.Analysis;  use Libadalang.Analysis;
with Libadalang.Iterators; use Libadalang.Iterators;

procedure Main is

   Ctx   : Analysis_Context := Create;

   function Get_Unit (Filename : String) return Analysis_Unit is
      Unit : constant Analysis_Unit := Get_From_File (Ctx, Filename);
   begin
      if Has_Diagnostics (Unit) then
         for D of Diagnostics (Unit) loop
            Put_Line ("error: " & Filename & ": "
                      & Langkit_Support.Diagnostics.To_Pretty_String (D));
         end loop;
         raise Program_Error with "Parsing error";
      end if;
      return Unit;
   end Get_Unit;

   Unit     : constant Analysis_Unit := Get_Unit ("pkg.ads");
   P        : constant Ada_Node_Predicate := new Ada_Node_Kind_Filter'
     (Kind => Ada_Object_Decl);
   Decls    : constant Ada_Node_Array := Find (Root (Unit), P).Consume;
   D1       : constant Object_Decl := Decls (1).As_Object_Decl;
   D2       : constant Object_Decl := Decls (2).As_Object_Decl;
   N        : constant Expr := D2.F_Default_Expr;
   Resolved : Object_Decl;
begin
   Put_Line ("D1: " & D1.Short_Image);
   Put_Line ("D2: " & D2.Short_Image);

   if not D2.P_Resolve_Names then
      raise Program_Error with "Resolution failed";
   end if;

   Resolved := N.P_Referenced_Decl.As_Object_Decl;
   Put_Line ("Resolved: " & Resolved.Short_Image);

   if D1.As_Ada_Node /= D1 then
      raise Program_Error with "Tag makes comparison fail";
   end if;

   if D1.As_Ada_Node = Resolved then
      raise Program_Error with "Entity info ignored";
   end if;

   Destroy (Ctx);
   Put_Line ("Done.");
end Main;
