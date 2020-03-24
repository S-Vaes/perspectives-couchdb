// BEGIN LICENSE
// Perspectives Distributed Runtime
// Copyright (C) 2019 Joop Ringelberg (joopringelberg@perspect.it), Cor Baars
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Full text of this license can be found in the LICENSE file in the projects root.

// END LICENSE

var EventSource = require('eventsource');

// This function will be called from Perspectives Core if it want to set up an internal channel to a GUI.
// emitStep will be bound to the constructor Emit, finishStep will be the constructor Finish.
// databaseUrl should point to the database. It need not be terminated with a slash.
function createChangeEmitterImpl (databaseUrl, emit, finish, emitter)
{
  var es = new EventSource(url + "/_changes?feed=eventsource");

  // Set the handler.
  es.onmessage = function(e) {
    // Emit the change to Purescript.
    emit( emitter, e )();
  }

  // Return the event source object.
  return es;
}

function closeEventSourceImpl( es )
{
  es.close();
}

module.exports = {
  createChangeEmitterImpl: createChangeEmitterImpl,
  closeEventSourceImpl: closeEventSourceImpl
};
