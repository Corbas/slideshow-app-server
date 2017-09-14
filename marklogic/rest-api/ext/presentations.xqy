xquery version "1.0-ml";

module namespace slides = "http://marklogic.com/rest-api/resource/presentations";

import module namespace json = "http://marklogic.com/xdmp/json"
    at "/MarkLogic/json/json.xqy";
    
import module namespace su = "http://www.corbas.co.uk/ns/slides-utils"
    at "/slide-utils.xqy";

declare namespace roxy = "http://marklogic.com/roxy";
declare namespace rapi = "http://marklogic.com/rest-api";
declare namespace pres = "http://www.corbas.co.uk/ns/presentations";
  

(:
  Generate a list of the presentations in the database. Return XML or JSON depending on 
  requested format (either in the 'format' parameter or the header. If the headers allow for 
  both XML & JSON and no format is defined, return XML. A basic outline of the decks in the
  presentations is returned. 
  
  If a single presentation is requested (using the presentation parameter) then detail level
  is increased and the title and id of all slides is returned. 
  
:)
declare 
%roxy:params("presentation=xs:string?,format=xs:string?")
function slides:get(
  $context as map:map,
  $params  as map:map
) as document-node()*
{

  let $content-type as xs:string? := su:get-format($context, $params)
  let $presentation-id as xs:string? := map:get($params, 'presentation')
  
   let $presentations as object-node()* :=   
      if ($presentation-id) 
      then slides:load-single-presentation($presentation-id)
      else slides:load-all-presentations()

    return if ($content-type) 
    then
      if ($presentation-id) 
        then slides:single-presentation-as($context, $content-type, $presentations)
        else slides:all-presentations-as($context, $content-type, $presentations)     
    else 
      su:bad-content-type($context)

};

(:
  Update a slide's visibility in a presentation. Given the ids of the presentation
  and deck, the slide id is added to the excludes array if not present and removed
  if it is present. No checking is done on the slide id as no particular damage is 
  done if it is not correct (this should change in future).
  
  There isn't any particularly obvious thing to return from this call. In order
  to be reasonable about this we treat it as a call to get the presentation 
  and return the changed result (note - had to create the 'changed' doc in order
  to return it as we are in a transaction and don't see the change).
  
  NOTE: how do we sanitise inputs properly in ML REST extensions? 
:)
declare 
%roxy:params("presentation=xs:string,deck=xs:string,slide=xs:string,format=xs:string?")
%rapi:transaction-mode("update")
function slides:post(
  $context as map:map,
  $params as map:map,
  $input as document-node()*
) as document-node()*
{
  let $dummy := xdmp:log("At initial log")

  let $content-type as xs:string? := su:get-format($context, $params)
  let $presentation-id  as xs:string? := map:get($params, 'presentation')
  let $deck-id as xs:string? := map:get($params, 'deck')
  let $slide-id as xs:string? := map:get($params, 'slide')
  
  (: Because this call returns data, we need to know if we have a reasonable
     content type before we do anything - updating and then finding an error
     would be bad 
  :)
  let $dummy := if (not($content-type)) 
    then su:bad-content-type($context)
    else ()
  
  (: If any are missing we have an error :)
  let $dummy := if (not($presentation-id) or not($deck-id) or not($slide-id))
    then fn:error((), "RESTAPI-SRVEXERR", (400, "Parameter(s) missing", 
        "The presentation, deck and slide parameters are required."))
    else ()
    
  let $presentation as object-node() := slides:load-single-presentation($presentation-id)
  
  (: find the deck within that presentation :)
  let $deck as object-node()? := $presentation/decks[id = $deck-id]

  (: It's an error if that deck is not present :)
  let $dummy := if (not($deck))
    then fn:error((), "RESTAPI-SRVEXERR", (404, "Deck not found.", 
        concat("The presentation with id ", $presentation-id, " does not contain the deck with id ", $deck-id)))
    else ()  
  
  (: Now check for the presence of the slide. We append it to the array and update if not present and
     remove it and update if it is :)
  let $excludes := $deck/array-node('exclude')
  
  let $new-excludes := if ($slide-id = $excludes/node()) 
    then array-node { $excludes/node()[not(. = $slide-id)] }
    else array-node { ($excludes/node(), $slide-id) }
    
  (: Update :)
  let $dummy := xdmp:node-replace($excludes, $new-excludes)
  
  (: Build an 'updated' copy of the input to return :)
  let $new-presentation := object-node {
    'id': $presentation/id,
    'title': $presentation/title,
    'description': $presentation/description,
    'author': $presentation/author,
    'updated': $presentation/updated,
    'decks': array-node {
    for $deck in $presentation/decks 
      return if ($deck/id = $deck-id) 
        then object-node { 'id': $deck/id, 'exclude': $new-excludes }
        else $deck }
  }
  
  
  return slides:single-presentation-as($context, $content-type, $new-presentation )
    
};


(:
  Choose whether to return a single presentation as XML or JSON
:)
declare function slides:single-presentation-as(
  $context as map:map, 
  $format as xs:string, 
  $presentation as object-node()) as document-node()*
{
    map:put($context, 'output-types', $format),
    map:put($context, "output-status", (200, "OK")),
    if ($format eq 'application/json') 
      then document { $presentation } 
      else document { slides:presentation-as-xml($presentation) } 
};

(:
  Choose whether to return the presentations info as XML or JSON
  (the document in the DB is natively JSON) but we default to returning XML
:)
declare function slides:all-presentations-as(
  $context as map:map, 
  $format as xs:string, 
  $presentations as object-node()*) as document-node()*
{ 
    map:put($context, 'output-types', $format),
    map:put($context, "output-status", (200, "OK")),
    if ($format eq 'application/json') 
      then document { array-node { $presentations }} 
      else document { 
        <pres:presentations>
        {
          for $pres in $presentations return slides:presentation-as-xml($pres) 
        }
        </pres:presentations> }   
};


(:
  Load a single presentation from the presentations document
:)
declare function slides:load-single-presentation($presentation-id as xs:string) as object-node()
{
    let $pres as object-node() := 
      document('/presentations/presentations.json')/array-node()/object-node()[id = $presentation-id]
    
    return 
      if ($pres) then $pres
      else fn:error((), "RESTAPI-SRVEXERR", (404, "Presentation not found", 
        concat("Presentations with id ", $presentation-id, " not found")))
};


(:
  Load all the documents from the input and return as a sequence of nodes
  rather than an array (in order to make the rest of the code work consistently)
:)
declare function slides:load-all-presentations() as object-node()*
{
   document('/presentations/presentations.json')/array-node()/object-node()
};

(:
  Return the JSON document as XML. It needs a little reformatting
  to be as we want it.
:)
declare function slides:presentation-as-xml($presentation as object-node()) as element(pres:presentation)
{

  <pres:presentation id="{$presentation/id}">       
      <pres:title>{$presentation/title}</pres:title>
      <pres:author>{$presentation/author}</pres:author>
      <pres:updated>{$presentation/updated}</pres:updated> 

      <decks>
      { 
        for $deck in $presentation/decks return 
          <pres:deck id="{$deck/id}">
          {  
            for $slide in $deck/exclude return
              <pres:exclude>{$slide/data()}</pres:exclude>
          }
          </pres:deck>
       }
       </decks>
  </pres:presentation>
};


