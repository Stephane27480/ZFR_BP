class ZCL_FR_BP_INSEE_SIREN definition
  public
  final
  create public .

public section.

  methods CONSTRUCTOR .
  class-methods GET_VAT_FROM_SIREN
    importing
      !IV_SIREN type STCD2
    returning
      value(RV_VAT) type STRING .
  methods GET_SIRET_FROM_VAT_CP
    importing
      !IV_VAT type STCEG
      !IV_POSTAL_CODE type AD_PSTCD1
    returning
      value(MT_VALUE) type ZFR_BP_INSEE_T .
  methods GET_SIRET_FROM_NAME_CP
    importing
      !IV_NAME type STRING
      !IV_POSTAL_CODE type AD_PSTCD1
    returning
      value(MT_VALUE) type ZFR_BP_INSEE_T .
  methods GET_SIRET_FROM_SIREN_CP
    importing
      !IV_SIREN type STCD2
      !IV_POSTAL_CODE type AD_PSTCD1
    returning
      value(MT_VALUE) type ZFR_BP_INSEE_T .
protected section.
private section.

  types:
    BEGIN OF ts_token,
      access_token TYPE string,
      scope        TYPE string,
      token_type   TYPE string,
      expires_in   TYPE string,
    END OF ts_token .
  types:
    BEGIN OF ts_header,
            statut  TYPE char03,
            message TYPE char255,
            total   TYPE i,
            debut   TYPE i,
            nombre  TYPE i,
          END OF ts_header .
  types:
    BEGIN OF ts_etablissement,
           siren                          TYPE stcd2,
           nic                            TYPE num5,
           siret                          TYPE stcd1,
           statutDiffusionEtablissement   TYPE char01,
           dateCreationEtablissement      TYPE char10,
           trancheEffectifsEtablissement  TYPE i,
           anneeEffectifsEtablissement    TYPE num4,
           activitePrincipaleRegistreMeti TYPE char6, ">30 car activitePrincipaleRegistreMetiersEtablissement
           dateDernierTraitementEtablisse TYPE char10, ">30 car dateDernierTraitementEtablissement
           etablissementSiege             TYPE abap_bool,
           nombrePeriodesEtablissement    TYPE i,
           uniteLegale                    TYPE REF TO data,
           adresseEtablissement           TYPE REF TO data,
           adresse2Etablissement          TYPE REF TO data,
           periodesEtablissement          TYPE REF TO data,
         END OF ts_etablissement .
  types:
    tt_etablissement type standard table of ts_etablissement with key siren nic .
  types:
    begin of ts_response,
   header type ts_header,
   etablissements type tt_etablissement,
  END OF ts_response .

  data MO_CLIENT type ref to IF_HTTP_CLIENT .
  data MS_TOKEN type TS_TOKEN .
  data MT_ETABLISSEMENT type TT_ETABLISSEMENT .
  data MT_VALEUR type ZFR_BP_INSEE_T .

  methods GET_TOKEN .
  methods GET_DATE
    returning
      value(RV_DATE) type CHAR10 .
  methods AUTHENTICATE
    importing
      !IV_USER type STRING
      !IV_PASSWORD type STRING
      !IO_HTTP type ref to IF_HTTP_CLIENT .
  methods GET_ACCESS
    importing
      !IV_SERVICE type CHAR255
    returning
      value(RS_SERVICE) type ZFR_BP_SERVICE_S .
  methods CALL_SERVICE
    importing
      !IV_PARAM type STRING .
  methods READ_RESPONSE .
  methods MAP_UNITE_LEGALE
    importing
      !IO_DATA type ref to DATA
    changing
      !CS_INSEE type ZFR_BP_INSEE_S .
  methods MAP_ADRESSE_ETABLISSEMENT
    importing
      !IO_DATA type ref to DATA
    changing
      !CS_INSEE type ZFR_BP_INSEE_S .
  methods MAP_RESPONSE .
ENDCLASS.



CLASS ZCL_FR_BP_INSEE_SIREN IMPLEMENTATION.


  METHOD AUTHENTICATE.
    DATA: l_utility TYPE REF TO if_http_utility,
          logon     TYPE string,
          logon_b64 TYPE string.
    CREATE OBJECT l_utility TYPE cl_http_utility.

    CONCATENATE iv_user ':' iv_password INTO logon.
    logon_b64 = l_utility->encode_base64( logon ).
    CONCATENATE 'Basic' logon_b64 INTO logon_b64            "#EC NOTEXT
       SEPARATED BY space.
    CALL METHOD io_http->request->set_header_field
      EXPORTING
        name  = 'Authorization' "#EC NOTEXT
        value = logon_b64.
  ENDMETHOD.


  METHOD call_service.
    DATA : lv_auth  TYPE string,
           lo_util  TYPE REF TO cl_HTTP_UTILITY,
           lv_date  TYPE char10,
           lv_query TYPE string.

    CLEAR me->mt_valeur.

    CREATE OBJECT lo_util.
    lv_date = me->get_date( ).

    CONCATENATE 'AND periode(etatAdministratifEtablissement:A)&date=' lv_date INTO lv_query.

    CONCATENATE iv_param   lv_query INTO lv_query SEPARATED BY space.

    lo_util->set_query( request = me->mo_client->request
                        query = lv_query
                        ).

    "setting request method
    me->mo_client->request->set_method( 'GET').

    "adding headers
    CONCATENATE me->ms_token-token_type me->ms_token-access_token INTO lv_auth SEPARATED BY space.
    me->mo_client->request->set_header_field( name = 'Authorization' value = lv_auth ).

    "   me->mo_client->request->set_content_type( content_type = 'application/json' ).

    CALL METHOD me->mo_client->send
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        http_invalid_timeout       = 4
        OTHERS                     = 5.
    IF sy-subrc = 0.
      CALL METHOD me->mo_client->receive
        EXCEPTIONS
          http_communication_failure = 1
          http_invalid_state         = 2
          http_processing_failed     = 3
          OTHERS                     = 5.
    ENDIF.

    me->read_response( ).
    me->map_response( ).

  ENDMETHOD.


  METHOD CONSTRUCTOR.
    CONSTANTS :
               lc_url TYPE string VALUE 'https://api.insee.fr/entreprises/sirene/V3/siret'.

    "get the token
    me->get_token( ).

    CALL METHOD cl_http_client=>create_by_url
      EXPORTING
        url                = lc_url
      IMPORTING
        client             = me->mo_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4.

  ENDMETHOD.


  METHOD GET_ACCESS.
    CONSTANTS:lv_function_id TYPE if_fdt_types=>id VALUE 'E50DBFCC84561EDE86C7625E1CC882CC'.
    DATA:lv_timestamp  TYPE timestamp,
         lt_name_value TYPE abap_parmbind_tab,
         ls_name_value TYPE abap_parmbind,
         lr_data       TYPE REF TO data,
         lx_fdt        TYPE REF TO cx_fdt,
         la_service    TYPE if_fdt_types=>element_text.
    FIELD-SYMBOLS <la_any> TYPE any.
****************************************************************************************************
* Au sein d'un cycle de traitement, tous les appels de méthode appelant la même fonction doivent utiliser le même horodatage.
* Pour les appels suivants de la même fonction, il est conseillé d'exécuter tous les appels avec le même horodatage.
* Cela permet d'améliorer la performance du système.
****************************************************************************************************
* Si vous utilisez des structures ou des tables sans liaison du Dictionnaire ABAP, vous devez créer les différents types
* vous-même. Insérez le type de données adapté dans la ligne correspondante du code source.
****************************************************************************************************
    GET TIME STAMP FIELD lv_timestamp.
****************************************************************************************************
* Traiter la fonction sans enregistrement des données trace, transférer éléments de données de contexte par table des noms/des valeurs
****************************************************************************************************
* Préparer traitement de fonction :
****************************************************************************************************
    ls_name_value-name = 'SERVICE'.
    la_SERVICE = IV_SERVICE.
    GET REFERENCE OF la_SERVICE INTO lr_data.
    ls_name_value-value = lr_data.
    INSERT ls_name_value INTO TABLE lt_name_value.
    CLEAR ls_name_value.
****************************************************************************************************
* Créer objet de données pour sauvegarder la valeur de résultat après le traitement de la fonction
* Vous pouvez ignorer l'appel suivant si vous avez déjà déterminer une
* variable pour le résultat. Remplacez également le paramètre
* EA_RESULT dans l'appel de méthode CL_FDT_FUNCTION_PROCESS=>PROCESS
* avec la variable souhaitée.
****************************************************************************************************
    cl_fdt_function_process=>get_data_object_reference( EXPORTING iv_function_id      = lv_function_id
                                                                  iv_data_object      = '_V_RESULT'
                                                                  iv_timestamp        = lv_timestamp
                                                                  iv_trace_generation = abap_false
                                                        IMPORTING er_data             = lr_data ).
    ASSIGN lr_data->* TO <la_any>.
    TRY.
        cl_fdt_function_process=>process( EXPORTING iv_function_id = lv_function_id
                                                    iv_timestamp   = lv_timestamp
                                          IMPORTING ea_result      = rs_service
                                          CHANGING  ct_name_value  = lt_name_value ).
      CATCH cx_fdt INTO lx_fdt.
****************************************************************************************************
* Vous pouvez contrôler CX_FDT->MT_MESSAGE pour la gestion des erreurs.
****************************************************************************************************
    ENDTRY.
  ENDMETHOD.


  METHOD GET_DATE.
    DATA : lv_year  TYPE char4,
           lv_month TYPE char2,
           lv_day   TYPE char2.

    lv_year = sy-datum+0(4).
    lv_month = sy-datum+4(2).
    lv_day = sy-datum+6(2).

    CONCATENATE lv_year '-' lv_month '-' lv_day INTO rv_date.


  ENDMETHOD.


  METHOD get_siret_from_name_cp.
    DATA : lv_param TYPE string.

    CONCATENATE 'q=denominationUniteLegale:' iv_name ' AND codePostalEtablissement:' iv_postal_code INTO lv_param.
    me->call_service( lv_param ).

    mt_value = me->mt_valeur.
  ENDMETHOD.


  method GET_SIRET_FROM_SIREN_CP.
    data : lv_param type string.
      concatenate 'q=siren:' iv_siren ' AND codePostalEtablissement:' iv_postal_code into lv_param.
      me->call_service( lv_param ).

      mt_value = me->mt_valeur.
  endmethod.


  METHOD get_siret_from_vat_cp.
    DATA : lv_siren TYPE stcd2.

    lv_siren = iv_vat+4(9).
    me->get_siret_from_siren_cp( EXPORTING iv_siren = lv_siren
                                           iv_postal_code = iv_postal_code
                                ).
    mt_value = me->mt_valeur.
  ENDMETHOD.


  METHOD GET_TOKEN.
    CONSTANTS : lc_service TYPE char255 VALUE 'INSEE'.

    DATA : lo_client  TYPE REF TO if_http_client,
           lv_data    TYPE xstring,
           ls_service TYPE zfr_bp_service_s,
           lv_url type string.

    "get URL user and password
    ls_service = me->get_access( lc_service ).
    lv_url = ls_service-url.

    CALL METHOD cl_http_client=>create_by_url
      EXPORTING
        url                = lv_url
      IMPORTING
        client             = lo_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4.

    IF sy-subrc <> 0.
      "error handling
    ENDIF.

    "setting request method

*    "setting request method
    lo_client->request->set_method('POST').

    "adding headers
*    lo_client->request->set_header_field( name = 'Autorization' value = lv_auth ).
    me->authenticate(
            io_http = lo_client
            iv_user             = ls_service-user
            iv_password             = ls_service-password
    ).
    lo_client->request->set_content_type( content_type = 'application/x-www-form-urlencoded' ).

    "Set the form content

    lo_client->request->set_form_field(
       EXPORTING
         name  =     'grant_type'
         value =     'client_credentials'
     ).


    CALL METHOD lo_client->send
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        http_invalid_timeout       = 4
        OTHERS                     = 5.
    IF sy-subrc = 0.
      CALL METHOD lo_client->receive
        EXCEPTIONS
          http_communication_failure = 1
          http_invalid_state         = 2
          http_processing_failed     = 3
          OTHERS                     = 5.
    ENDIF.

    DATA(lv_response) = lo_client->response->get_cdata( ).

    /ui2/cl_json=>deserialize(
         EXPORTING
            json             = lv_response
*       jsonx            = iv_json
            pretty_name      = /ui2/cl_json=>pretty_mode-camel_case
*       assoc_arrays     =
*       assoc_arrays_opt =
*       name_mappings    =
*       conversion_exits =
         CHANGING
           data             = ms_token
       ).

  ENDMETHOD.


  METHOD GET_VAT_FROM_SIREN.
    DATA : lv_modulo TYPE num02.
    lv_modulo = ( ( 12 + ( 3 * ( iv_siren MOD 97 ) ) ) MOD 97 ).
    IF ( strlen( lv_modulo ) NE 2 ).
      "lv_modulo = |0{ lv_modulo }|.
      CONCATENATE '0' lv_modulo INTO lv_modulo.

    ENDIF.
    "rv_vat = |FR{ lv_modulo }{ iv_siren }| .
    CONCATENATE 'FR' lv_modulo iv_siren INTO rv_vat.
  ENDMETHOD.


  METHOD map_adresse_etablissement.

    FIELD-SYMBOLS : <data>    TYPE any,
                    <field>   TYPE any,
                    <r_field> TYPE any.
    IF io_data IS BOUND.
      ASSIGN io_data->* TO <data> .


      set_field :
*                 <data>  'DENOMINATION_UNITE_LEGALE'  CS_INSEE-name1 ,
*                 <data>  'activite_principale' CS_INSEE-NAME2 ,
*                 <data>  'categorie_juridique' CS_INSEE-NAME3 ,

                  <data>  'TYPE_VOIE_ETABLISSEMENT' cs_insee-streetabbr ,
                  <data>  'LIBELLE_VOIE_ETABLISSEMENT' cs_insee-street,
                  <data>  'NUMERO_VOIE_ETABLISSEMENT' cs_insee-house_num1 ,
                  <data>  'COMPLEMENT_ADDRESS_ETABLISSEME' cs_insee-str_suppl1 ,"rue2
                  <data>  'LIBELLE_COMMUNE_ETABLISSEMENT' cs_insee-city1 ,
                  <data>  'CODE_POSTAL_ETABLISSEMENT' cs_insee-post_code1 ,
                  <data>  'CODE_CEDEX_ETABLISSEMENT' cs_insee-post_code3 ,
                  <data>  'LIBELLE_CEDEX_ETABLISSEMENT' cs_insee-city2,
                  <data>  'INDICE_REPETITION_ETABLISSEMEN' cs_insee-house_num2 ,
                   <data>  'CODE_PAYS_ETRANGER_ETABLISSEME' cs_insee-land1 .


      IF cs_insee-land1 IS INITIAL.
        cs_insee-land1 = 'FR'.
      ENDIF.
    ENDIF.
  ENDMETHOD.


  METHOD map_response.
    DATA : ls_response TYPE zfr_bp_insee_s,
           ls_etab     TYPE ts_etablissement.

    LOOP AT me->mt_etablissement INTO ls_etab.
      ls_response-stcd1 = ls_etab-siret.
      ls_response-stcd2 = ls_etab-siren.
      ls_response-numic = ls_etab-nic.
      ls_response-jmzah = ls_etab-trancheeffectifsetablissement.
      ls_response-jmjah = ls_etab-anneeeffectifsetablissement.
      ls_response-eeohq = ls_etab-etablissementSiege.
      ls_response-stceg = me->get_vat_from_siren( ls_etab-siren ).
      me->map_unite_legale( EXPORTING io_data = ls_etab-unitelegale
                            CHANGING cs_insee = ls_response
                              ).

      me->map_adresse_etablissement( EXPORTING io_data = ls_etab-adresseetablissement
                                    CHANGING cs_insee = ls_response
                              ).
      APPEND ls_response TO me->mt_valeur.
    ENDLOOP.

  ENDMETHOD.


  METHOD map_unite_legale.
    FIELD-SYMBOLS : <data>    TYPE any,
                    <field>   TYPE any,
                    <r_field> TYPE any.
    IF io_data IS BOUND.
      ASSIGN io_data->* TO <data> .

      set_field :
                 "  <data>  'activite_principale' cs_insee-is_type ," TB038A
                 " <data>  'ACTIVITE_PRINCIPALE_UNITE_LEGA' cs_insee-ind_sector ," TB038A
                 " <data>  'CATEGORIE_JURIDIQUE_UNITE_LEGA'  cs_insee-gform , "TVGF
                 "<data>  'categorie_entreprise' me->gv_entreprise ,
                 <data>  'NIC_SIEGE_UNITE_LEGALE' cs_insee-nicsg,
                  <data>  'DENOMINATION_UNITE_LEGALE' cs_insee-name1 ,
                  <data>  'DENOMINATION_USUELLE1UNITE_LEG' cs_insee-name2 ,
                  <data>  'DENOMINATION_USUELLE2UNITE_LEG' cs_insee-name3 .

      IF cs_insee-name1 IS INITIAL.
        set_field :
                 <data>  'NOM_UNITE_LEGALE' cs_insee-name1 ,
                 <data>  'PRENOM1UNITE_UNITE_LEGALE' cs_insee-name2 ,
                 <data>  'PRENOM2UNITE_UNITE_LEGALE' cs_insee-name3 .

      ENDIF.
    ENDIF.
  ENDMETHOD.


  METHOD read_response.
    DATA : ls_response TYPE ts_response.
    DATA(lv_response) = me->mo_client->response->get_cdata( ).

    /ui2/cl_json=>deserialize(
             EXPORTING
                json             = lv_response
*       jsonx            = iv_json
                pretty_name      = /ui2/cl_json=>pretty_mode-camel_case
*       assoc_arrays     =
*       assoc_arrays_opt =
*       name_mappings    =
*       conversion_exits =
             CHANGING
               data             = ls_response
           ).

if ls_response-header-statut eq 200.
  me->mt_etablissement = ls_response-etablissements.
else.
  "raise exception
endif.




  ENDMETHOD.
ENDCLASS.
