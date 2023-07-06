*"* use this source file for any macro definitions you need
*"* in the implementation part of the class
define set_field.

    assign component &2 of structure &1 to <r_field>.
    if <r_field> is assigned.
      assign  <r_field>->* to <field>.
      &3 = <field>.
    clear : <r_field>, <field>.
    endif.
 end-of-definition.
