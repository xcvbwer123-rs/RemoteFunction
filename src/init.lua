--// Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

--// Types
type Client = {
    Fire: (self: RemoteFunction, ...any) -> ...any;
    Event: (...any) -> ...any;
}

type Server = {
    Fire: (self: RemoteFunction, Player: Player, ...any) -> ...any;
    Event: (Player: Player, ...any) -> ...any;
}

export type RemoteFunction = {
    Name: string;
    Timeout: number;
    ErrorWhenTimedOut: boolean;

    InvokeServer: (self: RemoteFunction, ...any) -> ...any;
    InvokeClient: (self: RemoteFunction, Player: Player, ...any) -> ...any;

    OnServerInvoke: (Player: Player, ...any) -> ...any;
    OnClientInvoke: (...any) -> ...any;
}

export type Constructor = {
    newServer: (Name: string) -> RemoteFunction & Server;
    newClient: (Name: string) -> RemoteFunction & Client;
    new: (Name: string) -> RemoteFunction & (Client | Server);
}

--// Variables
local module = {__remotes = {}} :: Constructor
local IsServer = RunService:IsServer()
local voidFunction = (function()end)()

local Exceptions = { -- | 오류메세지 모음
    INVALID_KEY = "%s is not a property of %s";
    TRIED_TO_CALL_CONTRUCTOR = "Attempt to call a constructor.";
    TRIED_TO_CHANGE_READONLY = "Attempt to change property %s, the property is read-only.";
    SERVER_ONLY_METHOD = "This method is only can called by server.";
    CLIENT_ONLY_METHOD = "This method is only can called by client.";
    TIMEOUT_MESSAGE = "Request session has been expired.";
}

local Keys = { -- | Read-only값, __index, __newindex 가능값 모음
    Name = false;
    Timeout = true;
    OnServerInvoke = true;
    OnClientInvoke = true;
    Event = true;
}

local AltPaths = { -- | 진짜 변수명 위치들
    Name = "__name";
    Timeout = "__timeout";
    OnServerInvoke = "__handler";
    OnClientInvoke = "__handler";
    Event = "__handler";
}

local ConstructorOnly = { -- | 메인 클래스에서만 사용 가능한 함수들 (.new로 생성된거는 사용불가)
    new = true;
    newServer = true;
    newClient = true;
}

--// Funcitons
-- << Internal Functions >>
-- | 기존 assert함수에 level값 지원을 안해서 따로 만들어줌
local function assert(Check: boolean?, ErrorMsg: string?, Level: number?)
    if not Check then
        return error(ErrorMsg, (Level or 1) + 1)
    end
end

-- | 리모트 가져오는 생성함수
local function GetRemoteEvent(Name: string)
    if IsServer then
        local RemoteEvent = script:FindFirstChild(Name) or Instance.new("RemoteEvent")
        
        RemoteEvent.Name = Name
        RemoteEvent.Parent = script

        return RemoteEvent
    else
        return script:WaitForChild(Name)
    end
end

-- | 타임아웃 시킨 쓰레드 다시시작
local function ResolveTimeout(self, SessionId)
    task.spawn(self.__handlingThreads[SessionId][1], true)
end

-- | 세션 uid 생성
local function GenerateSessionId(SessionList)
    local Response

    repeat
        Response = HttpService:GenerateGUID(false)
    until SessionList[Response] == nil

    return Response
end

-- | 리모트 이벤트 핸들링 함수
local function HandleEvent(RemoteEvent: RemoteEvent)
    local RemoteName = RemoteEvent.Name
    local RemoteFunction = module.__remotes[RemoteName]

    -- | 리모트값 변경 금지
    RemoteEvent.Changed:Connect(function()
        if RemoteEvent.Parent ~= script then RemoteEvent.Parent = script end
        if RemoteEvent.Name ~= RemoteName then RemoteEvent.Name = RemoteName end
    end)

    if IsServer then
        RemoteEvent.OnServerEvent:Connect(function(Player: Player, IsResponse: boolean, SessionId: string, ...)
            if not RemoteFunction then RemoteFunction = module.__remotes[RemoteName] end

            if typeof(IsResponse) == "boolean" and typeof(SessionId) == "string" and #SessionId == 36 then
                if not IsResponse then
                    RemoteEvent:FireClient(Player, true, SessionId, pcall(RemoteFunction.__handler, Player, ...))
                elseif RemoteFunction.__handlingThreads[SessionId] then
                    local ThraedData = RemoteFunction.__handlingThreads[SessionId]

                    RemoteFunction.__handlingThreads[SessionId] = void

                    task.cancel(ThraedData[2])
                    task.spawn(ThraedData[1], false, ...)

                    table.clear(ThraedData)
                    ThraedData = void
                end
            else
                Player:Kick("Invaild Remote Response")
                error(`[Remote Function]: Invaild Remote Response <Player {Player.UserId}>`)
            end
        end)
    else
        RemoteEvent.OnClientEvent:Connect(function(IsResponse: boolean, SessionId: string, ...)
            if not RemoteFunction then RemoteFunction = module.__remotes[RemoteName] end

            if typeof(IsResponse) == "boolean" and typeof(SessionId) == "string" and #SessionId == 36 then
                if not IsResponse then
                    RemoteEvent:FireServer(true, SessionId, pcall(RemoteFunction.__handler, ...))
                elseif RemoteFunction.__handlingThreads[SessionId] then
                    local ThraedData = RemoteFunction.__handlingThreads[SessionId]

                    RemoteFunction.__handlingThreads[SessionId] = void

                    task.cancel(ThraedData[2])
                    task.spawn(ThraedData[1], false, ...)

                    table.clear(ThraedData)
                    ThraedData = void
                end
            end
        end)
    end
end

-- | 리모트 오브젝트 생성
local function ReferenceRemote(Name: string)
    if module.__remotes[Name] then
        return module.__remotes[Name]
    else
        local RemoteFunction = {
            __name = Name;
            __event = GetRemoteEvent(Name);
            __handlingThreads = {};
            __handler = voidFunction;
            __timeout = 10;

            ErrorWhenTimedOut = true;
        }

        HandleEvent(RemoteFunction.__event)
        setmetatable(RemoteFunction, module)
    
        return RemoteFunction
    end
end

-- << Global Functions >>
function module:InvokeServer(...)
    assert(module ~= self, Exceptions.TRIED_TO_CALL_CONTRUCTOR, 2)
    assert(not IsServer, Exceptions.CLIENT_ONLY_METHOD, 2)
    
    local SessionId = GenerateSessionId(self.__handlingThreads)
    local RunningThread = coroutine.running()

    local TimeoutThread = self.__timeout < math.huge and task.delay(self.__timeout, ResolveTimeout, self, SessionId) or coroutine.create()

    self.__handlingThreads[SessionId] = {RunningThread, TimeoutThread}

    self.__event:FireServer(SessionId, ...)

    local Response = {coroutine.yield()}
    local IsTimeout = table.remove(Response, 1)
    local IsSucceed = table.remove(Response, 1)

    if IsTimeout and #Response == 0 then
        assert(not self.ErrorWhenTimedOut, Exceptions.TIMEOUT_MESSAGE, 2)
    end

    if not IsSucceed then
        error(Response[1], 2)
    end

    return table.unpack(Response)
end

function module:InvokeClient(Player: Player, ...)
    assert(module ~= self, Exceptions.TRIED_TO_CALL_CONTRUCTOR, 2)
    assert(IsServer, Exceptions.SERVER_ONLY_METHOD, 2)
    
    local SessionId = GenerateSessionId(self.__handlingThreads)
    local RunningThread = coroutine.running()

    local TimeoutThread = self.__timeout < math.huge and task.delay(self.__timeout, ResolveTimeout, self, SessionId) or coroutine.create()

    self.__handlingThreads[SessionId] = {RunningThread, TimeoutThread}

    self.__event:FireClient(Player, SessionId, ...)

    local Response = {coroutine.yield()}
    local IsTimeout = table.remove(Response, 1)

    if IsTimeout and #Response == 0 then
        assert(not self.ErrorWhenTimedOut, Exceptions.TIMEOUT_MESSAGE, 2)
    end

    return table.unpack(Response)
end

function module:__tostring()
    assert(module ~= self, Exceptions.TRIED_TO_CALL_CONTRUCTOR, 2)

    return `RemoteFunction <{self.__name}>`
end

function module:__index(Key: string)
    assert(module ~= self, Exceptions.TRIED_TO_CALL_CONTRUCTOR, 2)
    assert(not ConstructorOnly[Key] and (Keys[Key] ~= nil or rawget(module, Key) ~= nil), Exceptions.INVALID_KEY:format(Key, tostring(self)), 2)

    if typeof(rawget(module, Key)) == "function" and not ConstructorOnly[Key] then
        return rawget(module, Key)
    end

    return rawget(self, rawget(AltPaths, Key))
end

function module:__newindex(Key: string, Value: any)
    assert(module ~= self, Exceptions.TRIED_TO_CALL_CONTRUCTOR, 2)
    assert(Keys[Key] ~= nil, Exceptions.INVALID_KEY:format(Key, tostring(self)), 2)
    assert(Keys[Key], Exceptions.TRIED_TO_CHANGE_READONLY:format(Key), 2)

    return rawset(self, rawget(AltPaths, Key), Value)
end

--// Set Properties
module.new = ReferenceRemote
module.newServer = ReferenceRemote -- | 사실 셋다 같은 함수인데 자동완성을 위해서 연결해줌
module.newClient = ReferenceRemote -- | 사실 셋다 같은 함수인데 자동완성을 위해서 연결해줌

return module