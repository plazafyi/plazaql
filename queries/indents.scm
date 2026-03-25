; PlazaQL indentation queries

; Indent inside parenthesized blocks
(search_expression "(" @indent ")" @outdent)
(boundary_expression "(" @indent ")" @outdent)
(computation "(" @indent ")" @outdent)
(point_constructor "(" @indent ")" @outdent)
(bbox_constructor "(" @indent ")" @outdent)
(linestring_constructor "(" @indent ")" @outdent)
(polygon_constructor "(" @indent ")" @outdent)
(circle_constructor "(" @indent ")" @outdent)
(dataset_source "(" @indent ")" @outdent)
(method "(" @indent ")" @outdent)
(directive "(" @indent ")" @outdent)
(parenthesized_expression "(" @indent ")" @outdent)
(list_literal "[" @indent "]" @outdent)
(filter_paren_expression "(" @indent ")" @outdent)
