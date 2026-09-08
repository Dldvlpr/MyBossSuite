-- tests/fixtures/AlertData.lua
-- Faux fichier de data d'alertes, charge en dernier comme le ferait un .toc.
--
-- Le depot ne livre aucune data d'alerte reelle : declarer qu'un sort est
-- kickable ou qu'une zone est evitable sans l'avoir mesure serait un mensonge
-- fonctionnel, pas un placeholder. La suite de tests a quand meme besoin d'une
-- data pour verifier le chemin de lecture — la voici, explicitement fausse.

local _, ns = ...

ns.InterruptableData[18435] = true   -- Fireball Volley
ns.MoveAlertData[22274] = true       -- Fire Wall
